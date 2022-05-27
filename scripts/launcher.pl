#! /usr/bin/perl

#Copyright (C) 2021 Feiyu Du <fdu@wustl.edu>
#              and Washington University The Genome Institute

#This script is distributed in the hope that it will be useful, 
#but WITHOUT ANY WARRANTY or the implied warranty of 
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
#GNU General Public License for more details.


use strict;
use warnings;

umask 002;

use lib "/storage1/fs1/duncavagee/Active/SEQ/Chromoseq/process/perl5/lib/perl5";
use Spreadsheet::Read;
use File::Copy::Recursive qw(dircopy);
use JSON qw(from_json to_json);
use IO::File;
use File::Spec;
use File::Compare;

##THIS LAUNCHER SCRIPT NEEDS TO BE RUN ON DRAGEN NODE compute1-dragen-2 TO BE ABLE TO GET ILLUMINA RUN INFO STRING
die "Provide rundir, excel sample spreadsheet, and batch name in order" unless @ARGV == 3;

my ($rundir, $sample_sheet, $batch_name) = @ARGV;
die "$sample_sheet is not valid" unless -s $sample_sheet;

my $staging_dir = '/staging/runs/MyeloSeqHD';
my $staging_rundir = $staging_dir.'/rundir';
my $dir = '/storage1/fs1/duncavagee/Active/SEQ/MyeloSeqHD';

#check diff on two key files
for my $name (qw(MyeloseqHD.16462-1615924889.CoverageQC.hg38.bed myeloseq_hotspots.vcf.gz)) {
    my $staging = File::Spec->join($staging_dir, 'dragen_align_inputs', $name);
    my $process = File::Spec->join($dir, 'process', 'git', 'cle-myeloseqhd', 'accessory_files', $name);
    unless (compare($staging, $process)==0) {
        die "$staging and $process are not SAME !";
    }
}

if ($rundir =~ /$staging_rundir/) {
    if (-d $rundir) {
        print "$rundir is ready\n";
    }
    else {
        die "$rundir does not exist. globus-xfer it to /staging first";
    }
}
else {
    die "globus-xfer $rundir to dragen-2 staging first";
}

my $git_dir = File::Spec->join($dir, 'process', 'git', 'cle-myeloseqhd');

my $conf = File::Spec->join($git_dir, 'application.conf');
my $wdl  = File::Spec->join($git_dir, 'MyeloseqHD.wdl');
my $zip  = File::Spec->join($git_dir, 'imports.zip');
my $json_template = File::Spec->join($git_dir, 'MyeloseqHD.json');

my $group  = '/cle/wdl/haloplex';
my $queue  = 'pathology';
my $docker = 'registry.gsc.wustl.edu/apipe-builder/genome_perl_environment:compute1-20';

my $user_group = 'compute-duncavagee';

my $out_dir = File::Spec->join($dir, 'batchdir', $batch_name);
unless (-d $out_dir) {
    unless (mkdir $out_dir) {
        die "Failed to make directory $out_dir";
    }
}

#parsing CoPath dump for MRN, ACCESSION, DOB and Gender
my $copath_dump = '/storage1/fs1/duncavagee/Active/SEQ/Chromoseq/process/daily_accession/WML_Daily_Accession_Log_CLE.csv';
my $dump_fh = IO::File->new($copath_dump) or die "fail to open $copath_dump for reading";
my %hash;

while (my $l = $dump_fh->getline) {
    next if $l =~ /^Accession/;
    
    my @columns = split /,/, $l;
    my $id  = $columns[2].'_'.$columns[0];
    my $sex = $columns[4];

    if ($sex eq 'M') {
        $sex = 'male';
    }
    elsif ($sex eq 'F') {
        $sex = 'female';
    }
    else {
        #Gender U
        warn "WARN: unknown gender $sex found for $id";
    }

    $hash{$id} = {
        DOB => $columns[5],
        sex => $sex,
    };
}
$dump_fh->close;

#parse sample spreadsheet
my $data = Spreadsheet::Read->new($sample_sheet);
my $sheet = $data->sheet(1);

my $ds_str;
my $si_str;
my $seq_id = 2900000000;

my @cases_excluded;

for my $row ($sheet->rows()) {
    next if $row->[0] =~ /Run|Lane/i;
    unless ($row->[0] =~ /\d+/) {
        die "Lane number is expected, Check sample sheet spreadsheet";
    }
    my ($lane, $flowcell, $lib, $index_str, $exception) = @$row;

    $lib =~ s/\s+//g;
    my ($sample, $mrn, $accession) = $lib =~ /^([A-Z]{4}\-(\d+)\-([A-Z]\d+\-\d+)\-[A-Z0-9]+)\-lib/;

    unless ($mrn and $accession) {
        die "Library name: $lib must contain MRN, accession id and specimen type";
    }

    unless ((length($mrn) == 10 and $mrn =~ /^99/) or (length($mrn) == 9 and $mrn =~ /^(1|2)/)) {
        die "$lib has invalid MRN: $1  MRN must be either a 10-digit number starting with 99 or a 9-digit number starting with 1i or 2";
    }

    my $id = $mrn.'_'.$accession;
    unless (exists $hash{$id}) {
        if ($exception and $exception =~ /NOTRANSFER/) {
            print "$id is NOTRANSFER and no-matching of CoPath dump is ok\n";
        }
        else {
            die "FAIL to find matching $mrn and $accession from CoPath dump for library: $lib";
        }
    }

    my ($index) = $index_str =~ /([ATGC]{8})AT\-AAAAAAAAAA/;

    if ($exception) {
        if ($exception =~ /NOTRANSFER/) {
            push @cases_excluded, $lib.'_'.$index;
            $exception =~ s/,?NOTRANSFER//;
            $exception = 'NONE' if $exception =~ /^\s*$/;
        }
    }
    else {
        $exception = 'NONE';
    }

    my ($sex, $DOB);
    if ($hash{$id}) {
        $sex = $hash{$id}->{sex};
        $DOB = $hash{$id}->{DOB};
        unless ($sex eq 'male' or $sex eq 'female') {
            die "Unknown gender: $sex for library: $lib";
        }
    }
    else { #NOTRANSFER
        ($mrn, $accession, $sex, $DOB) = ('NONE') x 4;
    }
    
    $ds_str .= join ',', $lane, $lib, $lib, '', $index, '';
    $ds_str .= "\n";
    $si_str .= join "\t", $index, $lib, $seq_id, $flowcell, $lane, $lib, $sample, $mrn, $accession, $DOB, $sex, $exception;
    $si_str .= "\n";

    $seq_id++;
}

## DRAGEN sample sheet
my $dragen_ss  = File::Spec->join($out_dir, 'demux_sample_sheet.csv'); 
my $ss_fh = IO::File->new(">$dragen_ss") or die "Fail to write to $dragen_ss";
$ss_fh->print("[Settings]\n");
$ss_fh->print("AdapterBehavior,trim\n");
$ss_fh->print("AdapterRead1,GATCGGAAGAGCACACGTCTGAACTCCAGTCAC\n");
$ss_fh->print("AdapterRead2,AGATCGGAAGAGCGTCGTGTAGGGAAA\n");
$ss_fh->print("OverrideCycles,Y151;I8N2;U10;Y151\n");
$ss_fh->print("[Data]\n");
$ss_fh->print("Lane,Sample_ID,Sample_Name,Sample_Project,index,index2\n");
$ss_fh->print($ds_str);
$ss_fh->close;

## Sample Index
my $si = File::Spec->join($out_dir, 'sample_index');
my $si_fh = IO::File->new(">$si") or die "Fail to write to $si";
$si_fh->print($si_str);
$si_fh->close;

## Get RunInfoString
my $run_xml = File::Spec->join($rundir, 'RunParameters.xml');
unless (-s $run_xml) {
    die "RunParameters.xml $run_xml is not valid";
}
my $xml_fh = IO::File->new($run_xml) or die "Fail to open $run_xml";
my ($runid, $R1cycle, $R2cycle, $index1cycle, $index2cycle, $fcmode, $wftype, $instr, $side);

while (my $line = $xml_fh->getline) {
    if ($line =~ /<RunId>(\S+)<\/RunId>/) {
        $runid = $1;
    }
    elsif ($line =~ /<Read1NumberOfCycles>(\d+)<\/Read1NumberOfCycles>/) {
        $R1cycle = $1;
    }
    elsif ($line =~ /<Read2NumberOfCycles>(\d+)<\/Read2NumberOfCycles>/) {
        $R2cycle = $1;
    }
    elsif ($line =~ /<IndexRead1NumberOfCycles>(\d+)<\/IndexRead1NumberOfCycles>/) {
        $index1cycle = $1;
    }
    elsif ($line =~ /<IndexRead2NumberOfCycles>(\d+)<\/IndexRead2NumberOfCycles>/) {
        $index2cycle = $1;
    }
    elsif ($line =~ /<FlowCellMode>(\S+)<\/FlowCellMode>/) {
        $fcmode = $1;
    }
    elsif ($line =~ /<WorkflowType>(\S+)<\/WorkflowType>/) {
        $wftype = $1;
    }
    elsif ($line =~ /<InstrumentName>(\S+)<\/InstrumentName>/) {
        $instr = $1;
    }
    elsif ($line =~ /<Side>(\S+)<\/Side>/) {
        $side = $1;
    }
}
$xml_fh->close;

my $run_info_str = join ',', $runid, $instr, $side, $fcmode, $wftype, $R1cycle, $index1cycle, $index2cycle, $R2cycle; 

## Input JSON
my $inputs = from_json(`cat $json_template`);
$inputs->{'MyeloseqHD.OutputDir'}        = $out_dir;
$inputs->{'MyeloseqHD.IlluminaDir'}      = $rundir;
$inputs->{'MyeloseqHD.SampleSheet'}      = $si;
$inputs->{'MyeloseqHD.DemuxSampleSheet'} = $dragen_ss;
$inputs->{'MyeloseqHD.RunInfoString'}    = $run_info_str;

if (@cases_excluded and $inputs->{'MyeloseqHD.DataTransfer'} eq 'true') {
    $inputs->{'MyeloseqHD.CasesExcluded'} = join ',', @cases_excluded;
}

my $input_json = File::Spec->join($out_dir, 'MyeloseqHD.json');
my $json_fh = IO::File->new(">$input_json") or die "fail to write to $input_json";

$json_fh->print(to_json($inputs, {canonical => 1, pretty => 1}));
$json_fh->close;

my $out_log = File::Spec->join($out_dir, 'out.log');
my $err_log = File::Spec->join($out_dir, 'err.log');

my $cmd = "bsub -g $group -G $user_group -oo $out_log -eo $err_log -q $queue -R \"select[mem>16000] rusage[mem=16000]\" -M 16000000 -a \"docker($docker)\" /usr/bin/java -Dconfig.file=$conf -jar /opt/cromwell.jar run -t wdl --imports $zip -i $input_json $wdl";

system $cmd;
#print $cmd."\n";

