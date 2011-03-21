#!/usr/bin/perl
#
# Periodic file caching for Apache httpd
# Invoke this command as follows in httpd.conf.
# CustomLog "|pcache.pl" "%>s %O %f"
#
# Copyright (c) JAIST FTP Admins <ftp-admin@jaist.ac.jp>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

use strict;
use warnings;
use Time::Local;
use Fcntl;
use File::Basename;
use File::Path;
use File::Temp ':mktemp';

##### please customize below ######
my $prefix="/var/opt/pcache"; # working directory for this scrpit

my $docroot = "/ftp"; # DocumentRoot
my $cacheroot = "/ftp/.cache"; # cache directory writable by this script
my $cache_total_size = 260 * 1000 * 1000 * 1000; # cache size

my $pipe_buf = 5120; # PIPE_BUF defined in sys/param.h
my $maxsymlinks = 20; # MAXSYMLINKS defined in sys/param.h 
my $cp_cmd = '/usr/bin/cp';
my $cp_opt = '-p';

my $min_file_size = 100000; # minimum file size to be cached
# pattern to exlude files from bing cached
my $exclude_pattern = qr{(?:\.(?:xml|sqlite)(?:\.gz|\.bz2)?|/(?:In)?Release|/(?:Packages|Sources|Contents-\w+)(?:\.gz|\.bz2)?)$};

my $sampling_rate = 1; # sampling rate (1/N) of requests
my $max_records = 5000; # number of records stored in traffic database

my $cache_interval = 7200; # interval to choose chaced files 
my $cache_factor = 0.02; # smoothing factor of exponential moving average
my $rank_interval = 1800; # interval to generate ranking or 0 if not necessary
my $rank_factor = 0.2;
my $hitrate_interval = 300; # interval to generate hit rate or 0 if not necessary
my $filesync_interval = 1800; # interval to sync cached files with originals
my $cache_cleanup_time = '06:00'; # time to clean up cache directory

# function to convert paths to categories in ranking
sub path_to_rank {
  $_ = shift;
  return $1 if m{^/pub/Linux/([^-/]+)};
  return $1 if m{^/pub/(PC-BSD)/};
  return $1 if m{^/pub/([^-/]+)};
  return "others";
}
##### please customize above ######

my $debug = 1;
my $data_dir = "$prefix/data";
-d $data_dir or mkdir($data_dir) or die $!;
my $cachelist_file = "$data_dir/cachefiles.txt";
my $cachedb_file = "$data_dir/cachedb.txt";
my $rankdb_file = "$data_dir/rankdb.txt";
my $rankjson_file = "$data_dir/ranking.json";
my $hitrate_file = "$data_dir/hitrate.txt";
my $log_dir = "$prefix/log";
-d $log_dir or mkdir($log_dir) or die $!;

my $debug_log = "$log_dir/debug.log";
my $cleanup_log = "$log_dir/cleanup.log";
my $filesync_log = "$log_dir/filesync.log";

my %cachedb;
my %rankdb;
my %cached_files;

my $cache_time = time + $cache_interval;
my $filesync_time = time + $filesync_interval;
my $rank_time = $rank_interval ? time + $rank_interval : undef;
my $hitrate_time = $hitrate_interval ? time + $hitrate_interval : undef;
my $cleanup_time = &calc_cleanup_time;

my $alarm = 0;
my $filesync_running = 0;
my $filesync_pid;
my $cache_vol = 0;
my $cache_vol_hit = 0;

if ($debug) {
  open(STDOUT, '>>', $debug_log) or die $!;
  open(STDERR, '>&STDOUT') or die $!;
  select STDERR; $| = 1;
  select STDOUT; $| = 1;
}

&main;

sub main {
  child_main(start_reader());
}
 
sub start_reader {
  pipe(my $in, my $out);
  defined(my $pid = fork) or die $!;
  if ($pid) {
    $SIG{CHLD} = sub { wait; exit(1); };
    close($in);
    my $flags = fcntl($out, F_GETFL, 0) or die $!;
    $flags |= O_NONBLOCK;
    fcntl($out, F_SETFL, $flags) or die $!;
    my $buf = "";
    my $len = 0;
    my $count = 0;
    while (<STDIN>) {
      next unless m(^2\d\d (\d+) ($cacheroot|$docroot)(.+[^/\n])$);
      next if ++$count < $sampling_rate;
      $count = 0;
      $buf .= "$1 $2 $3\n";
      $len = length($buf);
      next if $len < $pipe_buf;
      my $written = syswrite($out, $buf, $len);
      next unless $written;
      $buf = substr($buf, $written, $len - $written);
    }
    close($out);
    wait;
    exit(0);
  }
  close($out);
  return $in;
}

sub child_main {
  my $pipe = shift;
  $SIG{ALRM} = sub { $alarm = 1; };
  $SIG{TERM} = sub {
    kill TERM => $filesync_pid if $filesync_running;
    wait; exit(0);
  };

  my $hitrate_vol = 0;
  my $hitrate_vol_hit = 0;
  %cachedb = read_db($cachedb_file);
  %rankdb = read_db($rankdb_file) if $rank_time;
  read_cachelist();

  set_alarm($cache_time, $filesync_time, $rank_time, $hitrate_time, $cleanup_time);

  while (<$pipe>) {
    /^(\d+) ([^ ]+) (.*)$/;
    my ($vol, $root, $req) = ($1, $2, $3);

    if ($hitrate_time) {
      $hitrate_vol_hit += $vol if $root eq $cacheroot;
      $hitrate_vol += $vol;
    }
    $cache_vol_hit += $vol if $root eq $cacheroot;
    $cache_vol += $vol;
    $cachedb{$req} += $vol * $cache_factor;
    $rankdb{$req} += $vol * $rank_factor if $rank_time;
    next unless $alarm;

    my $time = time;
    if ($hitrate_time && $time >= $hitrate_time) {
      open(my $fh, '>', $hitrate_file) or die $!;
      printf $fh "%.1f\n", $hitrate_vol_hit / $hitrate_vol * 100;
      close($fh);
      $hitrate_vol = $hitrate_vol_hit = 0;
      $hitrate_time = $time + $hitrate_interval;
      print(localtime() .": hitrate\n") if $debug;
    }
    if ($rank_time && $time >= $rank_time) {
      gen_rankjson(update_rankdb());
      $rank_time = $time + $rank_interval;
    }
    if ($time >= $cache_time) {
      update_cachedb();
      unless ($filesync_running) {
	update_cachelist(); 
	run_filesync();
	$filesync_time = $time + $filesync_interval;
      }
      $cache_time = $time + $cache_interval;
    }
    if ($time >= $filesync_time) {
      run_filesync() unless $filesync_running;
      $filesync_time = $time + $filesync_interval;
    }
    if ($time >= $cleanup_time) {
      cleanup_cache() unless $filesync_running;
      $cleanup_time = calc_cleanup_time();
    }
    set_alarm($cache_time, $filesync_time, $rank_time, $hitrate_time, $cleanup_time);
  }
  kill TERM => $filesync_pid if $filesync_running;
  exit(0);
}

sub calc_cleanup_time {
  my ($h, $m) = split(/:/, $cache_cleanup_time);
  my ($day, $mon, $year) = (localtime)[3, 4, 5];
  my $r = timelocal(0, $m, $h, $day, $mon, $year);
  $r += 86400 if ($r <= time);
  return $r;
}

sub read_cachelist {
  return unless open(my $fh, '<', $cachelist_file);
  while (<$fh>) {
    chop;
    $cached_files{$_} = 1 if -f $docroot . $_;
  }
  close($fh);
}

sub read_db {
  my $file = shift;
  return () unless open(my $fh, '<', $file);
  my %hash;
  while (<$fh>) {
      chop;
      next unless (/^(.+) ([^ ]+)$/);
      $hash{$1} = $2 + 0;
  }
  close($fh);
  return %hash;
}

sub set_alarm {
  my $time = time;
  my $min = $time; #dummy
  for (@_) {
    next unless $_;
    my $diff = $_ - $time;
    if ($diff <= 0) {
      $alarm = 1;
      return;
    }
    $min = $diff if $diff < $min;
  }
  $alarm = 0;
  alarm $min;
}

sub update_rankdb
{
  my $num_records = 0;
  my $total = 0;
  my %data;
  open(DATA, ">", $rankdb_file . ".new") or die $!;
  foreach (sort { $rankdb{$b} <=> $rankdb{$a} } keys %rankdb) {
    $data{&path_to_rank($_)} += $rankdb{$_};
    $total += $rankdb{$_};
    if ($num_records < $max_records) {
      $num_records++;
      $rankdb{$_} *= (1 - $rank_factor);
      print DATA $_ .' '.  $rankdb{$_} . "\n";
    } else {
      delete $rankdb{$_};
    }
  }
  close(DATA);
  rename($rankdb_file, $rankdb_file . ".old");
  rename($rankdb_file . ".new", $rankdb_file);
  print(localtime() .": update rankdb\n") if $debug;
  return $total, %data;
}

sub gen_rankjson {
  my ($total, %data) = @_;
  my @order = sort { $data{$b} <=> $data{$a} } keys %data;
  open my $json, '>', $rankjson_file or die $!;
  print $json '[ ';
  print $json '{ "target": "'. $order[$_]. '", "value": '. sprintf("%.1f", 100 * $data{$order[$_]} / $total) . '}, ' for (0..9);
  my $others;
  $others += $data{$order[$_]} for (10..$#order);
  print $json '{ "target": "Others", "value": '.  sprintf("%.1f", 100 * $others / $total) . '} ]';
  close $json;
}

sub update_cachedb {
  my $num_records = 0;
  open(my $fh, ">", $cachedb_file . ".new") or die $!;
  foreach (sort { $cachedb{$b} <=> $cachedb{$a} } keys %cachedb) {
    if ($num_records < $max_records) {
      $num_records++;
      $cachedb{$_} *= (1 - $cache_factor);
      print $fh $_ .' '.  $cachedb{$_} . "\n";
    } else {
      delete $cachedb{$_};
    }
  }
  close($fh);
  rename($cachedb_file, $cachedb_file . ".old");
  rename($cachedb_file . ".new", $cachedb_file);
  print(localtime() .": update cachedb\n") if $debug;
}

my $update_start;
my @cache_add_list;
my @cache_delete_list;

sub update_cachelist {
  $update_start = time;
  my $total = 0;
  my %symlink;
  my %resolved;
  for my $f (keys %cachedb) {
    my $real = resolve_symlink($f, \%symlink, 1);
    if ($real ne $f) {
      $cachedb{$real} += $cachedb{$f};
      delete $cachedb{$f};
      push(@{$resolved{$real}}, $f);
    }
  }
  for my $f (sort { $cachedb{$b} <=> $cachedb{$a} } keys %cachedb) {
    my $size;
    if ($f !~ $exclude_pattern &&
	$total + $min_file_size <= $cache_total_size &&
	($size = (stat($docroot . $f))[12]) &&
	$size > $min_file_size &&
	$total + ($size *= 512) <= $cache_total_size) {
      $total += $size;
      push(@cache_add_list, $f) unless ($cached_files{$f});
      $cached_files{$f} = 2;
      next unless $resolved{$f};
      resolve_symlink($_, \%symlink, 0) for @{$resolved{$f}};
    }
  }
  open(my $fh, ">", $cachelist_file . ".new") or die $!;
  foreach (sort keys(%cached_files)) {
    unless (--$cached_files{$_}) {
	delete($cached_files{$_});
	unlink($cacheroot . $_);
	push(@cache_delete_list, $_);
	next;
    }
    print $fh $_ . "\n";
  }
  close($fh);
  rename($cachelist_file, $cachelist_file . ".old");
  rename($cachelist_file . ".new", $cachelist_file);
  print(localtime() .": update cachelist\n") if $debug;

  output_cache_report();
  undef @cache_add_list;
  undef @cache_delete_list;
}

sub output_cache_report {
  my @t = localtime;
  my $report = sprintf("%04d%02d%02d%02d%02d", $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1]);
  open(my $fh, ">", "$log_dir/$report.log");

  print $fh "Start at ". localtime($update_start) ."\n";
  print $fh "End at ". localtime() . "\n";
  print $fh "Cached Files: ". (keys %cached_files) ."\n";
  print $fh "Hit Rate: ". sprintf("%.1f", $cache_vol_hit / $cache_vol * 100) ."\n";
  $cache_vol = $cache_vol_hit = 0;

  print $fh "\n=== List of files removed from cache ===\n";
  print $fh $_ ."\n" for sort @cache_delete_list;
  print $fh "\n=== List of files added to cache ===\n";
  print $fh $_ ."\n" for sort @cache_add_list;
  close($fh);
}

# resolve relative symlinks and create symlinks on cache directory
sub resolve_symlink {
  my ($req, $cache, $dryrun) = @_;
  my $symlink = 0;
  my @resolved;
  $req =~ s(/+)(/)g; # eliminate redundant slashs
  my @left = split(m(/), $req);
  while (defined (my $name = shift @left)) {
    if ($name eq '.') {
      next;
    } elsif ($name eq '..') {
      return undef if $#resolved < 0;
      pop(@resolved);
      next;
    }
    my $path = join('/', @resolved, $name);
    my $link = $cache->{$path};
    if ($link) {
      if ($link eq $path) { # not symlink
	push(@resolved, $name);
	next;
      }
      return $req if (++$symlink > $maxsymlinks); # ELOOP
    } else {
      if (-l $docroot . $path) {
	return $req if (++$symlink > $maxsymlinks); # ELOOP
	$link = readlink($docroot . $path) or return $req;
	return $req if $link =~ m(^/);
	$cache->{$path} = $link;
	create_symlink($path, $link) unless $dryrun;
      } else {
	$cache->{$path} = $path;
	push(@resolved, $name);
	next;
      }
    }
    unshift(@left, split(m(/), $link));
  }
  return join('/', @resolved);
}

sub create_symlink {
  my ($path, $link) = @_;

  my $oncache = readlink($cacheroot . $path);
  unless ($oncache && $oncache eq $link) {
    rmtree($cacheroot . $path);
    my $dir = $cacheroot . dirname($path);
    # parent directory must not symlink nor file.
    if (-l $dir || !-d _) {
      unlink($dir);
      mkpath($dir);
    }
    $link =~ /^(.*)$/; $link = $1; #untaint
    symlink($link, $cacheroot . $path); 
    print(localtime() .": symlink: $cacheroot$path -> $link\n") if $debug;
  }
}

sub cleanup_cache {
  print(localtime() .": cache cleanup\n") if $debug;
  traverse_tree($cacheroot, $cacheroot, {});
  print(localtime() .": done cache cleanup\n") if $debug;
}

sub traverse_tree {
  my ($dir, $real, $dirhash) = @_;
  opendir(my $dh, $dir) or return;
  my @names = readdir($dh);
  closedir($dh);
  for (@names) {
    next if /^\.{1,2}\z/;
    my $full = (-l "$real/$_" ? follow_symlink("$real/$_") : "$real/$_");
    if (-d $full) {
      traverse_tree("$dir/$_", $full, $dirhash);
      if ($dirhash->{"$dir/$_"}) {
	$dirhash->{$dir} = 1
      } else {
	#empty directory
	if (-l "$dir/$_") {
	  unlink("$dir/$_");
	  print "unlink symlink $dir/$_\n" if $debug;
	} else {
	  rmdir("$dir/$_");
	  print "rmdir $dir/$_\n" if $debug;
	}
      }
    } elsif (-f _) {
      (my $key = $full) =~ s/$cacheroot//;
      if ($cached_files{$key}) {
	$dirhash->{$dir} = 1
      } else {
	unlink("$full");
	print "unlink $full\n" if $debug;
      }
    } else {
      #dangling symlink
      unlink("$dir/$_");
      print "unlink dangling symlink $dir/$_\n" if $debug;
    }
  }
}

sub follow_symlink {
  my $real = shift;
  do {
    my $link = readlink($real) or return undef;
    return undef if substr($link, 0, 1) eq '/'; # not allow absolute symlink 
    my $dir = substr($real, 0, rindex($real, '/') + 1);
    $link =~ s(/\z)();
    $real = $dir . $link;
    1 while $real =~ s(/[^/]+/\.\./)(/);
    1 while $real =~ s(/\./)(/);
  } while (-l $real);
  return $real;
}

sub run_filesync {
  defined($filesync_pid = fork) or die $!;
  if ($filesync_pid) {
    $filesync_running = 1;
    $SIG{CHLD} = sub { wait; $filesync_running = 0; };
    print(localtime() .": run filesync\n") if $debug;
    return;
  }
  $SIG{CHLD} = 'DEFAULT';
  for (sort keys(%cached_files)) {
    next unless my $src = (stat($docroot . $_))[9];
    my $dst = (stat($cacheroot . $_))[9];
    next if $dst && $dst == $src;
    rmtree($cacheroot . $_);
    my $dir = dirname($cacheroot . $_);
    unless (-d $dir) {
      unlink($dir);
      mkpath($dir);
    }
    my $tmpf = mktemp($dir .'/.XXXXXX');
    defined(my $pid = fork) or die $!;
    if ($pid) {
      $SIG{TERM} = sub { kill TERM => $pid; };
      wait;
      if ($? & 127) {
	print "interrupted ". ($? & 127) .": cp $_\n" if $debug;
	unlink($tmpf);
	exit 1;
      }
      if ($? >> 8) {
	print "failed: cp $_\n" if $debug;
	unlink($tmpf);
	next;
      }
      rename($tmpf, $cacheroot . $_) or die $!;
      print "done: cp $_\n" if $debug
    } else {
      exec $cp_cmd, $cp_opt, $docroot . $_, $tmpf;
      exit 1;
    }
  }
  print(localtime() .": done filesync\n") if $debug;
  exit(0);
}
