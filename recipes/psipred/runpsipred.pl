#!/usr/bin/perl

# This is a wrapper script to run PSIPRED
# written by Stefan Janssen, Feb 2017

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use Data::Dumper;
use File::Spec;

my $execdir = "./bin/";
my $datadir = "./data/";

my $inputfile = undef;
my $dbname = undef;
my $ncbidir = "";
my $mtx = 0;

&get_arguments();

# Generate a "unique" temporary filename root
my $hostid = qx(hostid); chomp $hostid;
my $tmproot = ($ENV{TMPDIR} ? exists $ENV{TMPDIR} : '').'psitmp'.$$.$hostid;
qx(mkdir -p $tmproot && cp -f $inputfile $tmproot/input); #($? != 0)

if ($mtx != 1) {
	blast();
} else {
	print "Re-using pre-computed PSI-BLAST with from file $inputfile ...\n";
	qx(cp $inputfile $tmproot/psiblast.mtx);
}
my $resfiles = psipred();
cleanup($resfiles);

sub cleanup {
	my ($resfiles) = @_;
	
	print "Cleaning up ...\n";
	my @filesToDelete = ('input', 'psiblast.chk', 'psiblast.blast', 'psiblast.pn', 'psiblast.sn', 'psiblast.mn', 'psiblast.aux', 'pass1.ss');
	push @filesToDelete, 'psiblast.mtx' if ($mtx != 1);
	foreach my $file (@filesToDelete) {
		qx(rm -f $tmproot/$file);
	}
	
	my $pwd = qx(pwd); chomp $pwd; $pwd .= '/';
	print "Final output files: ";
	foreach my $file (@{$resfiles}) {
		$file =~ s/^$pwd//;
		print $file." ";
	}
	print "Finished.\n";
}

sub psipred {
	print "Pass1 ...\n";

	my $filename = $tmproot.'/'.basename($inputfile);
	my $cmd = $execdir.'psipred '.$tmproot.'/psiblast.mtx '.$datadir.'weights.dat '.$datadir.'weights.dat2 '.$datadir.'/weights.dat3 > '.$tmproot.'/pass1.ss';
	qx($cmd);
	my $status = $?;
	if ($status != 0) {
		print "FATAL: Error whilst running psipred - script terminated!\n";
		exit $status;
	}

	print "Pass2 ...\n";
	$cmd = $execdir.'psipass2 '.$datadir.'weights_p2.dat 1 1.0 1.0 '.File::Spec->rel2abs($filename.'.ss2').' '.$tmproot.'/pass1.ss > '.File::Spec->rel2abs($filename.'.horiz');
	qx($cmd);
	$status = $?;
	if ($status != 0) {
		print "FATAL: Error whilst running psipass2 - script terminated!\n";
		exit $status;
	}
	
	return [File::Spec->rel2abs($filename.'.ss2'), File::Spec->rel2abs($filename.'.horiz')]
}

sub blast {
	print "Running PSI-BLAST with sequence $inputfile ...\n";
		
	my $cmd = $ncbidir.'blastpgp -b 0 -v 5000 -j 3 -h 0.001 -d '.$dbname.' -i '.$tmproot.'/input -C '.$tmproot.'/psiblast.chk &> '.$tmproot.'/psiblast.blast';
	qx($cmd);
	my $status = $?;
	if ($status != 0) {
		system("tail ${tmproot}/psiblast.blast");
		print "FATAL: Error whilst running blastpgp - script terminated!\n";
		exit $status
	}

	print "Predicting secondary structure...\n";
	qx(echo 'psiblast.chk' > $tmproot/psiblast.pn);
	qx(echo 'input' > $tmproot/psiblast.sn);
	
	$cmd = $ncbidir.'makemat -P '.$tmproot.'/psiblast';
	qx($cmd);
	$status = $?;
	if ($status != 0) {
		print "FATAL: Error whilst running makemat - script terminated!\n";
		exit $status;
	}
}

sub get_arguments {
	my $result = GetOptions (
				"d=s" => \$dbname,
				"n=s" => \$ncbidir,
				"mtx=i" => \$mtx,
		        "h"  => sub {&usage;});

	&usage if (!$ARGV[0]);
	($inputfile) = @ARGV;
	
	# add a / to the end of dir if it's not empty or already existing
	foreach my $dir ($ncbidir, $execdir, $datadir) {
		$dir .= "/" if (length($dir) > 0) && ($dir !~ m|/$|);
	}
	
	# check presents of blastpgp
	my $test = qx(${ncbidir}blastpgp -version 2>&1);
	if ((not defined $test) || ($test !~ m/Number of database sequences to show one-line descri/)) {
		print STDERR "Can't find the program blastpgp in the NCBI directory $ncbidir\n"; 
		print STDERR "Please pass the correct NCBI location using the -n parameter or modify\n";
		print STDERR "the value at the top of the script..\n\n";
		exit 1;
	}
	
	# check presents makemat
	$test = qx(${ncbidir}makemat 2>&1);
	if ((not defined $test) || ($test !~ m/FATAL ERROR: Unable to open profiles file stdin\.pn/)) {
		print STDERR "Can't find the program makemat in the NCBI directory $ncbidir\n"; 
		print STDERR "Please pass the correct NCBI location using the -n parameter or modify\n";
		print STDERR "the value at the top of the script.\n\n";
		exit 1;	
	}
	
	# guess blast data dir
	if (not exists $ENV{'BLASTMAT'}) {
		my ($dir) = (qx(which blastpgp) =~ m|^(.*?)bin/blastpgp$|);
		$ENV{'BLASTMAT'} = $dir.'/data/';
	}
	
	# check if blast database is present
	if ((not defined $dbname) or ($dbname eq '')) {
		print STDERR "Please provide a PSI-BLAST database name via -d!\n";
		exit 1;
	}
	if (qx(ls ${dbname}* 2>&1) =~ m/No such file or directory/) {
		print STDERR "The database name for PSI-BLAST searches has not been set correctly.\n"; 
		print STDERR "Please pass it using the -d parameter or modify the value at the top of the script.\n\n";
		exit 1;
	}
	
	# check if input file exist
	if (! -e $inputfile) {
		print STDERR "Cannot read input file '$inputfile'.\n";
		exit 1;
	}		
}

# Usage
sub usage {
	my $progname = basename($0);
	print "Version 4.01\n\n";
	print "Usage: $progname [options] <fasta file>\n\n";
	print "Options:\n\n";
	print "-mtx <0|1>     Process PSI-BLAST .mtx files instead of fasta files. Default 0.\n";
	print "-n <directory> NCBI binary directory (location of blastpgp and makemat)\n";
	print "-d <path>      Database for running PSI-BLAST.\n";
	print "-h <0|1>       Show help. Default 0.\n";
	exit 1;
}
