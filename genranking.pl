#!/usr/bin/perl
#
# Traffic ranking generator for Apache httpd
# Invoke this command as follows in httpd.conf.
# CustomLog "|genranking.pl" "%>s %O %f"
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

##### please customize below ######
my $prefix="/var/opt/pcache"; # working directory for this scrpit
my $docroot = "/ftp"; # DocumentRoot
my $pipe_buf = 5120 * 10; # enough larger value than PIPE_BUF defined in sys/param.h
my $maxsymlinks = 20; # MAXSYMLINKS defined in sys/param.h 
my $sampling_rate = 10; # sampling rate (1/N) of requests
my $max_records = 5000; # number of records stored in traffic database
my $rank_interval = 600; # interval to generate ranking
my $rank_factor = 0.4;
# function to convert paths to categories in ranking
sub path_to_rank {
  $_ = shift;
  return $1 if m{^/pub/Linux/([^-/]+)};
  return $1 if m{^/pub/(PC-BSD)/};
  return $1 if m{^/pub/([^-/]+)};
  return "others";
}
##### please customize above ######

my $data_dir = "$prefix/data";
-d $data_dir or mkdir($data_dir) or die $!;
my $rankdb_file = "$data_dir/rankdb.txt";
my $rankjson_file = "$data_dir/ranking.json";
my %rankdb;
my $rank_time = time + $rank_interval;
my $alarm = 0;

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
      next unless m(^2\d\d (\d+) (?:$docroot)(.+[^/\n])$);
      next if $count++ < $sampling_rate;
      $count = 0;
      $buf .= "$1 $2\n";
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

  %rankdb = read_db($rankdb_file) if $rank_time;
  set_alarm($rank_time);
  while (<$pipe>) {
    /^(\d+) (.*)$/;
    my ($vol, $req) = ($1, $2);

    $rankdb{$req} += $vol * $rank_factor;
    next unless $alarm;

    my $time = time;
    if ($time >= $rank_time) {
      gen_rankjson(update_rankdb());
      $rank_time = $time + $rank_interval;
    }
    set_alarm($rank_time);
  }
  exit(0);
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

