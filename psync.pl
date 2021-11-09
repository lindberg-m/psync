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
my $ET  = Image::ExifTool->new; $ET->Options(FastScan => 2);
my %PARAMS = ( VERBOSE => 1, DRY_RUN => 0  );
my $usage = << "EOF";
usage:
  psync.pl [-h, -q, -d, --mv] SOURCE DESTINATION

  Optional arguments:
    -h, --help     Show this message and exit
    -q, --quiet    Don't print information to terminal
    -d, --dry-run  Don't actually copy/move files, just print
                   (unless --quiet is set)
    --mv           Move instead of copy files from SOURCE
                   to DESTINATION

  Positional arguments:
    SOURCE       Directory to search for images and videos
    TARGET       Directory to where files will be copied to

Psync obtain timestamps from file metadata and copies files to
the destination within folders and with names corresponding to
the timestamps of the files. Files are hashed to ensure that 
only unique files are copied.

EOF

{
  # A class to store image and video files and acces timestamps
  # for their creation date and md5sum
  #
  package MediaFile;
  sub new {
    my $class = shift;
    my $self = { _filename => shift, _timestamp => '', _digest => '' };
    bless $self, $class;
    return $self;
  }

  sub getFilename {
    my $self = shift;
    return $self->{_filename};
  }

  sub getTimestamp {
    my $self = shift;
    return $self->{_timestamp};
  }

  sub getDigest {
    my $self = shift;
    return $self->{_digest};
  }

  sub digestFile {
    my $self = shift;
    open my $fh, '<:raw', $self->{_filename} or die "Cannot open file: $self->{_filename}, $!\n";
    $MD5->addfile($fh);
    $self->{_digest} = $MD5->digest;
    $MD5->reset();
    close $fh;
    return $self->{_digest};
  }

  sub setTimestamp {
    my $self = shift;
    my $metadata = $ET->ImageInfo($self->{_filename});
    if ($metadata->{MIMEType} eq "video/mp4") {
      $self->{_timestamp} = $metadata->{MediaCreateDate};
    } else {
      $self->{_timestamp} = $metadata->{DateTimeOriginal};
    }
    return $self->{_timestamp};
  }
}

main();

sub main {
  my ($source_dir, $dest_dir) = parse_argv(\%PARAMS);

  my %cp;
  if ($PARAMS{MOVE}) {
    $cp{cmd} = \&move; $cp{cmd_str} = "mv"; $cp{str} = "move";
  } else {
    $cp{cmd} = \&copy; $cp{cmd_str} = "cp"; $cp{str} = "copy"
  }

  # In order to avoid checks against VERBOSE in each for-loop iteration,
  # $put is used instead of `print`. If verbosity is turned off,
  # it does nothing, otherwise it prints the passed string
  my $put;
  if ($PARAMS{VERBOSE}) { $put = sub { print shift }; } else { $put = sub { return 0 }; }

  my ($img_files, $duplicate_counts) = scan_dir($source_dir);
  for my $img (@{$img_files}) {
    my @dest  = suggest_destination($img);
    my $dfile = "$dest[1]$dest[2]";    # New timestamped filename plus extension
    my $ddir  = "$dest_dir/$dest[0]";  # Destination dir plus timestamped subdirs
    my $dpath = "$ddir/$dfile";        # Destination filepath

    # Check if file already exist at destination
    # If it does exist, and the md5sum is identical
    # to the current file, continue to next file.
    # Otherwise, rename the target file until a new name
    # is reached, or a file with identical md5sum is found.
    my $file_already_exist = 0;
    for (my $i = 0; -f $dpath; $i++) {
      if (digestFile($dpath) eq $img->getDigest) {
        $file_already_exist = 1;
        last;
      } else {
        $dfile = "$dest[1]($i)$dest[2]";
        $ddir  = "$dest_dir/$dest[0]";     # Destination dir plus timestamped subdirs
        $dpath = "$ddir/$dfile";           # Destination filepath
      }
    }

    my $filename = $img->getFilename();
    if ($file_already_exist) {
      $put->(sprintf("%s already exist at: %s\n", $filename, $dpath ));
      next;
    }

    $put->(sprintf("%s %s %s\n", $cp{cmd_str}, $filename, $dpath));
    unless ($PARAMS{DRY_RUN}) {
      unless (-d $ddir) {
        $put->("mkdir $ddir");
        make_path($ddir);
      }
      $cp{cmd}->($filename, $dpath) or print STDERR "Could not $cp{str} $filename $dpath\n";
    }
  }
  $put->("Nr of duplicate files found at source dir: $duplicate_counts\n");
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
      if ($ARGV[$i] eq '-q' || $ARGV[$i] eq '--quiet') {
        $params->{VERBOSE} = 0;
        next;
      }
      if ($ARGV[$i] eq '-d' || $ARGV[$i] eq '--dry-run') {
        $params->{DRY_RUN} = 1;
        next;
      }
      print STDERR "Unrecognized argument: $ARGV[$i]\n";
      die $usage;
    } else {
      $positional_args[$j++] = $ARGV[$i];
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
  my $img     = shift;
  my $oldname = $img->getFilename();
  my ($fext)  = $oldname =~ /(\.[^.]+)$/;
  my $ts      = parse_date($img->getTimestamp());
  my $subdir  = "$ts->{year}/$ts->{month}/$ts->{day}";
  my $newname = "$ts->{year}-$ts->{month}-$ts->{day}-$ts->{hour}.$ts->{minute}.$ts->{second}";
  return ($subdir, $newname, $fext);
}

sub scan_dir {
  # Takes a directory and search for image and video files
  # Returns an array of ImageFiles to be copied/moved and
  # an array of duplicate files that shouldn't be moved/copied.
  my $dir = shift;
  my %seen_md5sums;
  my @retval;
  my $duplicate_count = 0;

  # Right now, duplicate files are simply collected, whith no notion
  # of what file(s) are identical to the duplicate...

  # Scan for jpg, png, jpeg and mp4 files
  for my $imf (File::Find::Rule->file()
                               ->name( '*\.[jJ][pP][gG]',     '*\.[pP][nN][gG]',
                                       '*\.[jJ][pP][eE][gG]', '*\.[mM][pP]4')
                               ->in ($dir)) {

     my $image = MediaFile->new($imf);
     my $digest = $image->digestFile();
    
     if ($seen_md5sums{$digest}) {
       $duplicate_count++;
     } else {
       $seen_md5sums{$digest} = 1;
       $image->setTimestamp();
       push @retval, $image;
     }
  }
  return (\@retval, $duplicate_count);
}

sub parse_date {
  my $timestamp = shift;
  my ($ymd, $hms) = split / /, $timestamp;
  my ($y, $m, $d) = split /:/, $ymd;
  my ($h, $M, $s) = split /:/, $hms;
  return { year => $y, month  => $m, day    => $d,
           hour => $h, minute => $M, second => $s }
}

sub digestFile {
  my $filename = shift;
  open my $fh, '<:raw', $filename or die "Cannot open file: $filename, $!\n";
  $MD5->addfile($fh);
  my $digest = $MD5->digest;
  $MD5->reset();
  close $fh;
  return $digest
}

