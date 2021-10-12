#!/usr/bin/env perl

use strict;
use warnings;

use Digest::MD5;
use Image::ExifTool;
use File::Path "make_path";
use File::Basename;
use File::Find::Rule;
use File::Copy;

# GLOBALS
my $MD5 = Digest::MD5->new;
my $ET  = Image::ExifTool->new;

my %PARAMS = (
  VERBOSE => 0,
  DRY_RUN => 0  
);

my $usage = << "EOF";
usage:
  psync.pl [-h] [-v] [-d] SOURCE DESTINATION

  Optional arguments:
    -h, --help     Show this message and exit
    -v, --verbose  Increase terminal output
    -d, --dry-run  Don't actually copy

  Positional arguments:
    SOURCE       Directory to search for images and videos
    TARGET       Directory to where files will be copied

Psync obtain timestamps from file metadata and copies files to
the destination within folders and with names corresponding to
the timestamps of the files. Files are hashed to ensure that 
only unique files are copied.
EOF

use constant VIDEO_MIME => "video/mp4";

sub main {
  my ($source_dir, $dest_dir) = parse_argv(\%PARAMS);

  my $put;
  if ($PARAMS{VERBOSE}) { $put = sub { print shift }; } else { $put = sub { return 0 }; }

  my $img_files = scan_dir($source_dir);
  for my $img (@{$img_files}) {
    my @dest  = suggest_destination($img);
    my $dfile = "$dest[1]$dest[2]";    # New timestamped filename plus extension
    my $ddir  = "$dest_dir/$dest[0]";  # Destination dir plus timestamped subdirs
    my $dpath = "$ddir/$dfile";        # Destination filepath

    # Check if file already exist at destination
    # If it does exist, and the md5sum is identical
    # to the current file, continue to next file.
    # Otherwise, rename the target file until the
    # a new name is reached, or a file with identical
    # md5sum is found.
    my $file_already_exist = 0;
    my $i = 0;
    while (-f $dpath) {
      if (digest_file($dpath) eq $img->{digest}) {
        $file_already_exist = 1;
        last;
      } else {
        $dfile = "$dest[1].($i)$dest[2]";
        $ddir  = "$dest_dir/$dest[0]";     # Destination dir plus timestamped subdirs
        $dpath = "$ddir/$dfile";           # Destination filepath
        $i++;
      }
    }
    if ($file_already_exist) {
      $put->("$img->{filename} already exist at: $dpath\n" );
      next;
    }

    $put->("cp $img->{filename} $dpath\n");
    unless ($PARAMS{DRY_RUN}) {
      unless (-d $ddir) {
        $put->("mkdir $ddir");
        make_path($ddir);
      }
      copy($img->{filename}, $dpath) or print STDERR "Could not copy $img->{filename} to $dpath\n";
    }
  }
}

sub parse_argv {
  my @positional_args;
  my $params = shift;
  my $j = 0;
  for (my $i = 0; $i < @ARGV; $i++) {
    if ($ARGV[$i] =~ /^-/) {
      if ($ARGV[$i] eq '-h' || $ARGV[$i] eq '--help') {
        die $usage 
      }
      if ($ARGV[$i] eq '-v' || $ARGV[$i] eq '--verbose') {
        $params->{VERBOSE} = 1;
        next;
      }
      if ($ARGV[$i] eq '-d' || $ARGV[$i] eq '--dry-run') {
        $params->{DRY_RUN} = 1;
        next;
      }
      print STDERR "Unrecognized argument: $ARGV[$i]\n";
      die $usage;
    } else {
      $positional_args[$j] = $ARGV[$i];
      $j++;
    }
  }

  if ($j != 2) {
    print STDERR "Need two positional arguments, got $j\n";
    die $usage;
  }

  my $source = shift @positional_args;
  my $dest = shift @positional_args;
  return ($source, $dest)
}

sub suggest_destination {
  my $img    = shift; # Ref to element outputted from `scan_dir`

  my $oldname = $img->{filename};
  my ($fext)  = $oldname =~ /(\.[^.]+)$/;
  my $ts      = parse_date($img->{timestamp});
  my $subdir  = "$ts->{year}/$ts->{month}/$ts->{day}";
  my $newname = "$ts->{year}_$ts->{month}_$ts->{day}-$ts->{hour}.$ts->{minute}.$ts->{second}";
  return ($subdir, $newname, $fext);
}

sub scan_dir {
  # Takes a directory and search for image and video files
  # Returns an array of hashes with the fields:
  #   filename  -> /path/to/file.jpg
  #   timestamp -> 2020:02:22 13:37:37
  #   digest    -> 0871dc5b614a8aba0d7a31b823f13244
  my $dir = shift;
  my @retval;
  # Scan for jpg, png, jpeg and mp4 files
  for my $imf (File::Find::Rule->file()
                               ->name( '*\.[jJ][pP][gG]',     '*\.[pP][nN][gG]',
                                       '*\.[jJ][pP][eE][gG]', '*\.[mM][pP]4')
                               ->in ($dir)) {

     my $metadata = $ET->ImageInfo($imf);
     my $filetype = $metadata->{MIMEType};
     my $digest   = digest_file($imf);
     
     # Assume picture unless MIMEtype is mp4
     my $timestamp = $filetype eq VIDEO_MIME ? $metadata->{MediaCreateDate} : $metadata->{DateTimeOriginal};
     push @retval, {
       filename  => $imf,
       timestamp => $timestamp,
       digest    => $digest
     }
  }
  return \@retval;
}

sub parse_date {
  my $timestamp = shift;
  my ($ymd, $hms) = split / /, $timestamp;
  my ($y, $m, $d) = split /:/, $ymd;
  my ($h, $M, $s) = split /:/, $hms;
  return { year => $y, month  => $m, day    => $d,
           hour => $h, minute => $M, second => $s }
}

sub digest_file {
  my $fname = shift;
  open my $fh, '<:raw', $fname or die "Cannot open file: $fname\n";
  $MD5->addfile($fh);
  my $digest = $MD5->digest;
  $MD5->reset();
  close $fh;
  return $digest;
}

main()
