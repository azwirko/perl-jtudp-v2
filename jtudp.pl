#!/usr/bin/perl

# For Redpitaya & Pavel Demin FT8 code image @ http://pavel-demin.github.io/red-pitaya-notes/sdr-transceiver-ft8

# Gather decodes from FT8 log file /dev/shm/decodes-yymmdd-hhmm.txt  file of format 
# 181216 014645  34.7   4 -0.98  7075924 K1RA          FM18

# Uses /dev/shm/decode-ft8.log to determine when above file is ready for decoding

# sends WSJT-X UDP packets per definition
#   https://sourceforge.net/p/wsjt/wsjt/HEAD/tree/branches/wsjtx/NetworkMessage.hpp

# caches call signs for up to 15 minutes before resending - see $MINTIME

# v0.8.0 - 2018/12/15 - K1RA@K1RA.us

# Start by using following command line
# ./udp.pl YOURCALL YOURGRID HOSTIP UDPPORT
# ./udp.pl WX1YZ AB12DE 192.168.1.2 2237

use strict;
use warnings;

use IO::Socket;

# minimum number of minutes to cache calls before resending
my $MINTIME = 15;

# Software descriptor and version info
my $ID = "FT8-Skimmer";
my $VERSION = "0.8.0";
my $REVISION = "a";


# check for YOUR CALL SIGN
if( ! defined( $ARGV[0]) || ( ! ( $ARGV[0] =~ /\w\d+\w/)) ) { 
  die "Enter a valid call sign\n"; 
}
my $mycall = uc( $ARGV[0]);

# check for YOUR GRID SQUARE (6 digit)
if( ! defined( $ARGV[1]) || ( ! ( $ARGV[1] =~ /^\w\w\d\d\w\w$/)) ) { 
  die "Enter a valid 6 digit grid\n";
} 
my $mygrid = uc( $ARGV[1]);

# check for HOST IP
if( ! defined( $ARGV[2]) || ( ! ( $ARGV[2] =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)) ) { 
  die "Enter a valid IP address ex: 192.168.1.2\n";
} 
my $peerhost = $ARGV[2];

# check for UDP PORT
if( ! defined( $ARGV[3]) || ( ! ( $ARGV[3] =~ /^\d{2,5}$/)) ) { 
  die "Enter a valid UDP port number ex: 2237\n";
} 
my $peerport = $ARGV[3];

# WSJT-X UDP header
my $header = "ad bc cb da 00 00 00 02 ";
# pack header into byte array
$header = join( "", split(" ", $header));

# Message descriptors
my $msg0 = "00 00 00 00 ";
# pack msg0 into byte array
$msg0 = join( "", split(" ", $msg0));

my $msg1 = "00 00 00 01 ";
# pack msg1 into byte array
$msg1 = join( "", split(" ", $msg1));

my $msg2 = "00 00 00 02 ";
# pack msg2 into byte array
$msg2 = join( "", split(" ", $msg2));

my $msg6 = "00 00 00 06 ";
# pack msg6 into byte array
$msg6 = join( "", split(" ", $msg6));

my $maxschema = "00 00 00 03 ";
# pack maxschema into byte array
$maxschema = join( "", split(" ", $maxschema));

# holds one FT8 decoder log line from /dev/shm/decoder-ft8.log
my $line;

# FT8 decoder log fields
my $msg;
my $date;
my $gmt;
my $x;
my $dt;
my $snr;
my $freq;
my $call;
my $grid;

my $ft8msg;

# Msg 1 Local station info fields (only used by WSJT-X)
my $mode = "FT8";
my $dxcall = "AB1CDE";
my $report = "+12";
my $txmode = "FT8";
my $txen = 0;
my $tx = 0;
my $dec = 0;
my $rxdf = 1024;
my $txdf = 1024;
my $decall = $mycall;
my $degrid = $mygrid;
my $dxgrid = "AA99";
my $txwat = 0;
my $submode = "";
my $fast = 0;

my $decodes;
my $yr;
my $mo;
my $dy;
my $hr;
my $mn;

# lookup table to determine base FT8 frequency used to calculate Hz offset
my %basefrq = ( 
  "184" => 1840000,
  "183" => 1840000,
  "357" => 3573000,
  "535" => 5357000,
  "707" => 7074000,
  "1013" => 10136000,
  "1407" => 14074000,
  "1810" => 18100000,
  "1809" => 18100000,
  "2107" => 21074000,
  "2491" => 24915000,
  "2807" => 28074000,
  "5031" => 50313000
);

# used for calculating signal in Hz from base band FT8 frequency
my $base;
my $hz;

# flag to send new spot
my $send;

# decode current and last times
my $time;
my $ltime;
my $secs;

# hash of deduplicated calls per band
my %db;

# call + base key for %db hash array
my $cb;

# minute counter to buffer decode lines
my $min = 0;

# client socket
my $sock;


$| = 1;

# setup tail to watch FT8 decoder log file and pipe for reading

# if FT8 log is ready then open
if( -e "/dev/shm/decode-ft8.log") {
  open( LOG, "tail -f /dev/shm/decode-ft8.log |");
#print "Got it!\n";
} else {
# test for existence of log file and wait until we find it
  while( ! -e "/dev/shm/decode-ft8.log") {
#print "Waiting 5...\n";
    sleep 5;
  }
  open( LOG, "tail -f /dev/shm/decode-ft8.log |");
#print "Got it!\n";
}

# Loop forever
while( 1) {

# read in lines from FT8 decoder log file 
READ:
  while( $line = <LOG>) {
# check to see if this line says Decoding (end of minute for FT8 decoder)
    if( $line =~ /^Done/) { 
# derive time for previous minute to create decode TXT filename
      ($x,$mn,$hr,$dy,$mo,$yr,$x,$x,$x) = gmtime(time-60);

      $mo = $mo + 1;
      $yr = $yr - 100;

#print "$yr,$mo,$dy,$hr,$mn\n";

      $mn = sprintf( "%02d", $mn);
      $hr = sprintf( "%02d", $hr);
      $dy = sprintf( "%02d", $dy);
      $mo = sprintf( "%02d", $mo);

# create the filename to read based on latest date/time stamp
      $decodes = "decodes_".$yr.$mo.$dy."_".$hr.$mn.".txt";
#print "$decodes\n";

      if( ! -e "/dev/shm/".$decodes) {
#print "No decode file $decodes\n";
        next READ;
      }

# open TXT file for the corresponding date/time
      open( TXT,  "< /dev/shm/".$decodes);

# yes - send a heartbeat

# open socket 
      $sock = IO::Socket::INET->new(
        Proto    => 'udp',
        PeerPort => $peerport,
        PeerAddr => $peerhost,
      ) or die "Could not create socket: $!\n";

# Msg 0 - Heartbeat
      print $sock ( pack( "H*", $header) .
                    pack( "H*", $msg0) . 
                    pack( "N*", length( $ID)) . 
                    pack( "A*", $ID) .
                    pack( "H*", $maxschema) . 
                    pack( "N*", length( $VERSION)) . 
                    pack( "A*", $VERSION) . 
                    pack( "N*", length( $REVISION)) . 
                    pack( "A*", $REVISION)
      );

# close socket
      $sock->close();

# check if its been one hour decoding
      if( $min++ >= 60) {

# yes - loop thru cache on call+baseband keys
        foreach $cb ( keys %db) {
# extract last time call was seen        
          ( $ltime) = split( "," , $db{ $cb});

# check if last time seen > 1 hour        
          if( time() >= $ltime + 3600) {
# yes - purge record
            delete $db{ $cb};
          }
        }
# reset 60 minute timer
        $min = 0;
      }

# loop thru all decodes
MSG:
      while( $msg = <TXT>) {
# check if this is a valid FT8 decode line beginning with 6 digit time stamp
# 181216 014645  34.7   4 -0.98  7075924 K1RA          FM18
        if( ! ( $msg =~ /^\d{6}\s\d{6}/) ) {
# no - go to read next line from decoder log
          next MSG;
        }

# looks like a valid line split into variable fields
        ($date, $gmt, $x, $snr, $dt, $freq, $call, $grid)= split( " ", $msg);

# skip if no valid call or grid
        if( ( $call eq "") || ( ! ( $call =~ /\d/) ) || ( $grid eq "" ) ) { 
          next MSG; 
        }

#print $msg;
        
        $dxcall = $call;
        $dxgrid = $grid;
        $report = $snr;
        
# extract HHMM
        $gmt =~ /^(\d\d\d\d)\d\d/;
        $gmt = $1;

# get UNIX time since epoch  
        $time = time();
    
# determine base frequency for this FT8 band decode    
        $base = int( $freq / 10000);

# make freq an integer  
        $freq += 0;

        $ft8msg = $call . " " . $grid;
        
#print "$ft8msg\n";

# check cache if we have NOT seen this call on this band yet  
        if( ! defined( $db{ $call.$base}) ) { 
# yes - set flag to send it to client(s) 
          $send = 1;

# save to hash array using a key of call+baseband 
          $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
        } else {
# no - we have seen before - get last time call was sent to client
          ( $ltime) = split( ",", $db{ $call.$base});

# test if current time is > first time seen + MINTIME since we last sent to client
          if( time() >= $ltime + ( $MINTIME* 60) ) {
# yes - set flag to send it to client(s) 
            $send = 1;

# resave to hash array with new time
            $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
          } else {
# no - don't resend or touch time 
            $send = 0;
          }
        } # end if( ! defined - cache check

        $hz = int( $freq - $basefrq{ $base});

# send spot
        if( $send) {
#print "Send $call\n";

# open socket
          $sock = IO::Socket::INET->new(
            Proto    => 'udp',
            PeerPort => $peerport,
            PeerAddr => $peerhost,
          ) or die "Could not create socket: $!\n";

# Msg 1 - Location station info
          print $sock ( pack( "H*", $header) .
                        pack( "H*", $msg1) . 
                        pack( "N*", length( $ID)) . 
                        pack( "A*", $ID) .
                        pack( "N*", 0) .
                        pack( "N*", $basefrq{ $base}) . # pack( "N*", $freq) . send standard FT8 freq for RBN/Aggregator
                        pack( "N*", length( $mode)) . 
                        pack( "A*", $mode) .
                        pack( "N*", length( $dxcall)) . 
                        pack( "A*", $dxcall) .
                        pack( "N*", length( $report)) . 
                        pack( "A*", $report) .
                        pack( "N*", length( $txmode)) . 
                        pack( "A*", $txmode) .
                        pack( "h", $txen) .
                        pack( "h", $tx) .
                        pack( "h*", $dec) .
                        pack( "N*", $rxdf) .
                        pack( "N*", $txdf) .
                        pack( "N*", length( $decall)) . 
                        pack( "A*", $decall) .
                        pack( "N*", length( $degrid)) . 
                        pack( "A*", $degrid) .
                        pack( "N*", length( $dxgrid)) . 
                        pack( "A*", $dxgrid) .
                        pack( "h", $txwat) .
                        pack( "N*", length( $submode)) . 
                        pack( "A*", $submode) .
                        pack( "h", $fast)
          );

# close socket
          $sock->close();

# open socket
          $sock = IO::Socket::INET->new(
            Proto    => 'udp',
            PeerPort => $peerport,
            PeerAddr => $peerhost,
          ) or die "Could not create socket: $!\n";
  
# Msg 2 - FT8 decode message
          print $sock ( pack( "H*", $header) .
                        pack( "H*", $msg2) . 
                        pack( "N*", length( $ID)) . 
                        pack( "A*", $ID) .
                        pack( "h", 1) .
#                        pack( "N*", $secs) .
                        pack( "N*", 0) .
                        pack( "N*", $snr) .
                        pack( "d>", $dt) .
                        pack( "N*", $hz) .
                        pack( "N*", length( $mode)) . 
                        pack( "A*", $mode) .
                        pack( "N*", length( $ft8msg)) . 
                        pack( "A*", $ft8msg) .
                        pack( "h", 0) .
                        pack( "h", 0)
          );

# close socket
          $sock->close();
        } # end if( $send )

      } # end while( $msg = <TXT> - end of decodes

    } # end if( $line =~ /^Done/ - end of FT8 log decoder minute capture

  } # end while( $line = <LOG> 
  
} # end while(1) - repeat forever
