#!/usr/bin/perl
# $Rev: 11 $
# $Author: artem $
# $Date: 2009-05-23 23:09:47 -0700 (Sat, 23 May 2009) $

use List::MoreUtils 'first_index';
use Encode::Detect::Detector;
use LWP::Simple;
use IO::Socket;
use WebService::TVDB;
use Date::Calc qw(Add_Delta_Days);
use Data::Dumper;
use Getopt::Std;
use Mediainfo;
use Path::Class;
use File::Basename;
use Term::ANSIColor qw(:constants);
use Video::FrameGrab;
use XML::LibXML;
use File::Temp;
use Encode qw(encode decode);

$Term::ANSIColor::AUTORESET = 1;

my $choice = 0;
my $getvideoimage = 0;
my $getseason = 0;
my $getset = 0;
my $sname = "";
my $BASEDIR;
my $BASEFILENAME;
my $NFODIR;
my $nocache = 0;
my $getfileinfo = 0;
my $generateimages = 1;
my $debug = 0;

# declare the perl command line flags/options we want to allow
my %options=();
getopts("icsSn:o:f:", \%options);
$getvideoimage = 1 if defined $options{i};
$getseason = 1 if defined $options{s};
$getset = 1 if defined $options{S};
$sname = $options{n} if defined $options{n};
$getfileinfo = $options{f} if defined $options{f};
$nocache = 1 if defined $options{c};
$debug = 1 if defined $options{d};

my $apikey = 'MY-API-KEY';
my $tvdb = WebService::TVDB->new(api_key => $apikey, language => 'English', max_retries => 3);

# my $tvdb = TVDB::API::new( $apikey );

# $tvdb->setApiKey($apikey);

# $tvdb->setCacheDB("$ENV{HOME}/.tvdb.db");

# $tvdb->setConf(maxEpisode, 150);

my $rating;

my $FILENAME;
my $SERIES_NAME;
my $ORIG_SERIES_NAME;
my $SEASON;
my $EPPART;
my @EPISODES;

my $series;

sub getCodec
{
    my $codec = $_[0];

    foreach (lc($codec)) {
        /ac-3/i && do { return "AC3" };
        /aac.*/i && do { return "AAC" };
        /mpa1l3/i && do { return "MP3" };
    }
    return $codec;
}

sub _tohm
{
    my ($S) = @_;

    my $h = $S/60;
    my $m = $S%60;
    my $out = sprintf("%dh %02dm", $h, $m);
    return $out;
}


sub getBaseName
{
    my ($pfile) = @_;
    my ($name, $path, $suffix) = fileparse($pfile, '\.[^\.]*');

    return ($path, $name);
}


sub getDecodedValue {
    my ($myString) = @_;
    
    my $r;
    $r = eval { decode('UTF-8', $myString) } or $r = $myString;
    return $r;
}

sub printSeriesInfo {
    my ($doc, $root, $series, $all) = @_;

    $all = 0 unless $all;

    $series->fetch(); 
    
    # print Dumper $series;

    my $plot;
    my $value;
    my $node;

    my $BANNER = $series->banner;
    $doc->setDocumentElement($root);
    my $tvshow =  $doc->createElement("tvshow");
    $tvshow->setAttribute("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance");
    $tvshow->setAttribute("xmlns:xsd", "http://www.w3.org/2001/XMLSchema");
    $root->appendChild($tvshow);

    my $id = $doc->createElement("id");
    $text = XML::LibXML::Text->new($series->id);
    $id->appendChild($text);
    $tvshow->appendChild($id);

    if ($series->IMDB_ID) {
        $node = $doc->createElement("id");
        $node->setAttribute("moviedb", "imdb");
        $text = XML::LibXML::Text->new($series->IMDB_ID);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }

    my $title = $doc->createElement("title");
    $text = XML::LibXML::Text->new($series->SeriesName);
    $title->appendChild($text);
    $tvshow->appendChild($title);

    if ($series->{Rating}) {
        $node = $doc->createElement("rating");
        $text = XML::LibXML::Text->new($series->Rating);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }
    if ($series->{Overview}) {
        $node = $doc->createElement("plot");
        $text = XML::LibXML::Text->new(getDecodedValue($series->Overview));
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }
    if ($series->{ContentRating}) {
        $node = $doc->createElement("mpaa");
        $text = XML::LibXML::Text->new($series->ContentRating);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }

    if ($series->Genre) {
        foreach my $genre (@{$series->Genre}) {
            if ($genre ne "") {
                my $g = $doc->createElement("genre");
                $text = XML::LibXML::Text->new($genre);
                $g->appendChild($text);
                $tvshow->appendChild($g);
            }
        }
    }

    if ($series->FirstAired) {
        $node = $doc->createElement("premiered");
        $text = XML::LibXML::Text->new($series->FirstAired);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }
    if ($series->Network) {
        $node = $doc->createElement("company");
        $value = $series->Network;
        $text = XML::LibXML::Text->new($value);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }

    my $actors = $series->actors;

    foreach my $actor (@{$actors} ) {
        if ($actor) {
            $node_a = $doc->createElement("actor");

            $node = $doc->createElement("name");
            $value = $actor->Name;
            $text = XML::LibXML::Text->new($value);
            $node->appendChild($text);
            $node_a->appendChild($node);
            if ($actor->Role) {
                $node = $doc->createElement("role");
                $value = $actor->Role;
                $text = XML::LibXML::Text->new($value);
                $node->appendChild($text);
                $node_a->appendChild($node);
            }
            if ($actor->Image) {
                $node = $doc->createElement("thumb");
                $text = XML::LibXML::Text->new("http://www.thetvdb.com/banners/" . $actor->Image);
                $node->appendChild($text);
                $node_a->appendChild($node);
            }
            $tvshow->appendChild($node_a);
        }
    }

    my @directors;
    my @writers;
    my @ws;
    
    %seen   = ();
    foreach $ep (@{$series->episodes}) {
        if ($ep->Director) {
            @ws = split /[\|&,;]/, $ep->Director;
            foreach $w (@ws) {
                $w =~ s/(^ | $| (X))//;
                next if $w eq "";
                my $d = lc($w);
                next if $seen{ $d }++;
                push @directors, $w;
            }
        }
    }
    
    foreach my $director (@directors) {
        $node = $doc->createElement("director");
        $text = XML::LibXML::Text->new($director);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }
    
    %seen   = ();
    foreach $ep (@{$series->episodes}) {
        if ($ep->Writer) {
            @ws = split /[\|&,;]/, $ep->Writer;
            foreach $w (@ws) {
                $w =~ s/(^ | $| (X))//;
                next if $w eq "";
                my $d = lc($w);
                next if $seen{ $d }++;
                push @writers, $w;
            }
        }
    }
    
    foreach my $writer (@writers) {
        $node = $doc->createElement("credits");
        $text = XML::LibXML::Text->new($writer);
        $node->appendChild($text);
        $tvshow->appendChild($node);
    }
}

sub printEpisodeInfo
{
    my ($doc, $root, $series, $season, $episodenum) = @_;
    
    # Now print episode specific data
    $episodenum =~ s/^0//g;
    my $epInfo = $series->get_episode($season, $episodenum);
    
    $doc->setDocumentElement($root);
    $episode = $doc->createElement("episodedetails");
    $root->appendChild($episode);

#    print Dumper $epInfo;
#    print Dumper decode( 'utf8', $epInfo->{EpisodeName} );
    
    if ($epInfo->EpisodeName) {
        $node = $doc->createElement("title");
        $text = XML::LibXML::Text->new(getDecodedValue($epInfo->EpisodeName));
        $node->appendChild($text);
        $episode->appendChild($node);
    }
    if ($epInfo->FirstAired) {
        $node = $doc->createElement("aired");
        $text = XML::LibXML::Text->new($epInfo->FirstAired);
        $node->appendChild($text);
        $episode->appendChild($node);
    }
    if ($epInfo->Rating) {
        $node = $doc->createElement("rating");
        $text = XML::LibXML::Text->new($epInfo->Rating);
        $node->appendChild($text);
        $episode->appendChild($node);
    }

    $node = $doc->createElement("season");
    $text = XML::LibXML::Text->new($season);
    $node->appendChild($text);
    $episode->appendChild($node);

    $node = $doc->createElement("episode");
    $text = XML::LibXML::Text->new($episodenum);
    $node->appendChild($text);
    $episode->appendChild($node);

    if ($epInfo->Overview) {
        $node = $doc->createElement("plot");
        $text = XML::LibXML::Text->new(getDecodedValue($epInfo->Overview));
        $node->appendChild($text);
        $episode->appendChild($node);
    }

    my @writers = split(/\|/, $epInfo->Writer) if $epInfo->Writer;

    if (@writers) {
        foreach my $writer (@writers) {
            if ($writer ne "") {
                $node = $doc->createElement("credits");
                $text = XML::LibXML::Text->new($writer);
                $node->appendChild($text);
                $episode->appendChild($node);
            }
        }
    }

    if ($epInfo->Director) {
        $director = $epInfo->Director;
        $director =~ s/\|//g;

        $node = $doc->createElement("director");
        $text = XML::LibXML::Text->new($director);
        $node->appendChild($text);
        $episode->appendChild($node);
    }
    
    if ($epInfo->airsafter_season) {
        $node = $doc->createElement("airsAfterSeason");
        $text = XML::LibXML::Text->new($epInfo->airsafter_season);
        $node->appendChild($text);
        $episode->appendChild($node);
    }
    if ($epInfo->airsbefore_season) {
        $node = $doc->createElement("airsBeforeSeason");
        $text = XML::LibXML::Text->new($epInfo->airsbefore_season);
        $node->appendChild($text);
        $episode->appendChild($node);
    }
    if ($epInfo->airsbefore_episode) {
        $node = $doc->createElement("airsBeforeEpisode");
        $text = XML::LibXML::Text->new($epInfo->airsbefore_episode);
        $node->appendChild($text);
        $episode->appendChild($node);
    }
    
    if ($getfileinfo == 1) {
        my $mediafile = $FILENAME;
        $mediafile =~ s/\$/\\\$/g;
        my $media_info = new Mediainfo(filename => $mediafile);
        
        $fileinfo = $doc->createElement("fileinfo");

        $streamdetails = $doc->createElement("streamdetails");

        $audio = $doc->createElement("audio");
        if ($media_info->{audio_channels}) {
            $node = $doc->createElement("channels");
            $text = XML::LibXML::Text->new($media_info->{audio_channels});
            $node->appendChild($text);
            $audio->appendChild($node);
        }
        if ($media_info->{audio_codec}) {
            $node = $doc->createElement("codec");
            $text = XML::LibXML::Text->new($media_info->{audio_codec});
            $node->appendChild($text);
            $audio->appendChild($node);
        }
        $streamdetails->appendChild($audio);

        $video = $doc->createElement("video");
        if ($media_info->{dar}) {
            $node = $doc->createElement("aspect");
            $text = XML::LibXML::Text->new($media_info->{dar});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        if ($media_info->{fps}) {
            $node = $doc->createElement("framerate");
            $text = XML::LibXML::Text->new($media_info->{fps});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        if ($media_info->{video_codec}) {
            $node = $doc->createElement("codec");
            $text = XML::LibXML::Text->new($media_info->{video_codec});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        if ($media_info->{video_length}) {
            $node = $doc->createElement("durationinseconds");
            $text = XML::LibXML::Text->new($media_info->{video_length});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        if ($media_info->{height}) {
            $node = $doc->createElement("height");
            $text = XML::LibXML::Text->new($media_info->{height});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        if ($media_info->{width}) {
            $node = $doc->createElement("width");
            $text = XML::LibXML::Text->new($media_info->{width});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        if ($media_info->{scan_type}) {
            $node = $doc->createElement("scantype");
            $text = XML::LibXML::Text->new($media_info->{scan_type});
            $node->appendChild($text);
            $video->appendChild($node);
        }
        $streamdetails->appendChild($video);


        $fileinfo->appendChild($streamdetails);
        $episode->appendChild($fileinfo);
    }
    # get image
    if ($getvideoimage == 1) {
        $VIDEOIMAGEFILE = $BASEDIR . "/" . $BASEFILENAME . ".videoimage.jpg";
        my $index = first_index { /$episodenum/ } @EPISODES;
        # print Dumper @EPISODES;

        if (scalar(@EPISODES) > 1) {
            $VIDEOIMAGEFILE = $BASEFILENAME . ".videoimage_" . ($index + 1) . ".jpg";
        }


# 	my $epbanner = $tvdb->getEpisodeBanner($series_name, $season, $episode, , 1);

# 	print Dumper $epbanner;

        if ( $epInfo->filename ) {
            print STDERR "Downloading video image for episode $episodenum [$epInfo->{filename}]\n";
            LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $epInfo->filename, $VIDEOIMAGEFILE) unless -e $VIDEOIMAGEFILE;
        } elsif ($generateimages == 1) {
            print STDERR "Generating video image for episode $episodenum\n";
	    my ($hrs_range, $min_range, $sec_range);
	    my $mediafile = $FILENAME;
	    $mediafile =~ s/\$/\\\$/g;
	    my $media_info = new Mediainfo(filename => $mediafile);
	    my $duration = int(rand($media_info->{length}));
	    `ffmpeg -ss $duration -t 1 -i "$FILENAME" -f mjpeg "$VIDEOIMAGEFILE"`  unless -e $VIDEOIMAGEFILE;
        }
        
    }
}

sub getInfo
{
    $FILENAME = $_[0];
    my $f = file($FILENAME);
    
#    $tvdb->setBannerPath($f->absolute->parent);
    
    ($BASEDIR, $BASEFILENAME) = getBaseName($FILENAME);
    $NFODIR = $BASEDIR;
    $NFODIR = $options{o} if defined $options{o};

#    print Dumper ($NFODIR, $BASEDIR, $BASEFILENAME);
    
    # Now parse the filename to get the series name, season & episode
    $BASEFILENAME =~ m/^(.*)\sS(\d+)(E.*)\s.*/i;
    $SERIES_NAME = $1;
    $ORIG_SERIES_NAME = $1;
    $SEASON = $2 + 0;
    $EPPART = $3;
    @EPISODES = $EPPART =~ m/E(\d+)/g;
    $SERIES_NAME =~ s/\$3A/:/g;

    # override series name
    $SERIES_NAME = $sname unless $sname eq "";
    
    print STDERR "Searching for $SERIES_NAME...\n";

    my $series_list = $tvdb->search($SERIES_NAME);
    # print Dumper $series_list;
    
    # TODO: Print list, then choose appropriate. Similar to movie.pl
    $series = @{$series_list}[0];
    
    print STDERR "Finding details for $SERIES_NAME [with ID " . $series->id . "], season $SEASON, episodes ";
    foreach my $episode (@EPISODES) {
        print STDERR $episode . " ";
    }
    print STDERR "\n";
    
    $NFOFILE = XML::LibXML::Document->createDocument( "1.0", "UTF-8");
    my $root = $NFOFILE->createElement("xml");
    
    printSeriesInfo($NFOFILE, $root, $series);
    
    foreach my $episode (@EPISODES) {
        printEpisodeInfo($NFOFILE, $root, $series, $SEASON, $episode);
    }
    
#    print Dumper $series->banners;
    #($fh, $file) = tmpnam();
    $NFOFILE->toFile($BASEFILENAME . ".nfo", 1);
    #$NFOFILE->toFH($fh, 2);
    #system("iconv -fUTF-8 -tUTF-8 '" . $file . "' -o \"" . $BASEFILENAME . ".nfo\"");
    
    sub getBanner {
        my ($banners, $type, $type2, $season) = @_;
        
        my $out = "";
        my $rating = -1;
        foreach $banner (@{$banners}) {
            if ($banner->Language eq "en" && $type eq $banner->BannerType && $type2 eq $banner->BannerType2 && ((defined $season && $season eq $banner->Season) || (!defined $season))) {
                if (($banner->Rating || 0) > $rating) {
#                    print Dumper "Dude, found a banner";
#                    print Dumper $banner;
                    $out = $banner->BannerPath;
                    $rating = $banner->Rating;
                }
            }
        }
        return $out;
    }
    
    if ($EPISODES[0] == 1 or $getseason == 1) {
        $rating = -1;
        my $fposter;
        my $banner;
        my $fanart;

        my $POSTERFILE = $BASEDIR . $BASEFILENAME . ".jpg";
        my $BANNERFILE = $BASEDIR . $BASEFILENAME . ".banner.jpg";
        my $FANARTFILE = $BASEDIR . $BASEFILENAME . ".fanart.jpg";

        if (! -e $POSTERFILE ) {
            print STDERR "Downloading Season $SEASON Poster..\n";
            $fposter = getBanner($series->banners, "season", "season", $SEASON);
            
            if ($fposter eq "") {
                print STDERR " - No Season $SEASON poster, getting set poster...\n";
                $fposter = getBanner($series->banners, "poster", "680x1000");
            }

            if ($fposter ne "") {
                print STDERR "\t[http://www.thetvdb.com/banners/$fposter]\n";
                LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $fposter, $POSTERFILE );
            } else {
                print STDERR "Hmm. No Set poster either\n";
            }
        }
	    
        if (! -e $BANNERFILE ) {
            print STDERR "Downloading Season $SEASON banner..\n";
            $banner = getBanner($series->banners, "season", "seasonwide", $SEASON);
            
            if ($banner eq "") {
                print STDERR " - No Season $SEASON banner, getting set banner...\n";
                $banner = getBanner($series->banners, "series", "graphical");
            }

            if ($banner ne "") {
                print STDERR "\t[http://www.thetvdb.com/banners/$banner]\n";
                LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $banner, $BANNERFILE );
            } else {
                print STDERR "Hmm. No Set banner either\n";
            }
        }	    
        if (! -e $FANARTFILE ) {
            print STDERR "Downloading Season $SEASON Fanart..\n";
            $fanart = getBanner($series->banners, "fanart", "1920x1080");
            
            if ($fanart ne "") {
                print STDERR "\t[http://www.thetvdb.com/banners/$fanart]\n";
                LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $fanart, $FANARTFILE );
            } else {
                print STDERR "Hmm. No fanart found\n";
            }
        }   
    }

    if ($getset == 1 || ($EPISODES[0] == 1 && $SEASON <= 1)) {
        my $SET_NAME = $ORIG_SERIES_NAME;
        $SET_NAME =~ s/ \([0-9]*\)//;
        my $SETNFO = $NFODIR . "/Set_".$SET_NAME."_1.nfo";
        my $SETBANNER = $BASEDIR . "/Set_" . $SET_NAME . "_1.banner.jpg";
        my $SETPOSTER = $BASEDIR . "/Set_" . $SET_NAME . "_1.jpg";
        my $SETFANART = $BASEDIR . "/Set_" . $SET_NAME . "_1.fanart.jpg";

        print STDERR "Generating Set NFO...\n";
        $NFOFILE = XML::LibXML::Document->createDocument( "1.0", "UTF-8");
        my $root = $NFOFILE->createElement("xml");

        printSeriesInfo($NFOFILE, $root, $series, 1);

        $NFOFILE->toFile($SETNFO, 1);

        my $rating = -1;
        my $fposter;
        my $banner;
        my $fanart;

        if (! -e $SETPOSTER ) {
            print STDERR "Downloading Set Poster..\n";
            $fposter = getBanner($series->banners, "poster", "680x1000");

            if ($fposter ne "") {
                print STDERR "\t[http://www.thetvdb.com/banners/$fposter]\n";
                LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $fposter, $SETPOSTER );
            } else {
                print STDERR "Hmm. No Set poster found\n";
            }
        }
        if (! -e $SETBANNER ) {
            print STDERR "Downloading Set banner..\n";
            $banner = getBanner($series->banners, "series", "graphical");

            if ($banner ne "") {
                print STDERR "\t[http://www.thetvdb.com/banners/$banner]\n";
                LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $banner, $SETBANNER );
            } else {
                print STDERR "Hmm. No Set banner found\n";
            }
        }	    
        if (! -e $SETFANART ) {
            print STDERR "Downloading Season $SEASON Fanart..\n";
            $fanart = getBanner($series->banners, "fanart", "1920x1080");
            
            if ($fanart ne "") {
                print STDERR "\t[http://www.thetvdb.com/banners/$fanart]\n";
                LWP::Simple::getstore( "http://www.thetvdb.com/banners/" . $fanart, $SETFANART );
            } else {
                print STDERR "Hmm. No fanart found\n";
            }
        }
    }
}

# ok, now we can generate our NFO!
# printSeriesInfo($SERIES_NAME);
my $num_args = $#ARGV + 1;
if ($num_args < 1) {
    print "\nUsage: tv-episode-details.pl [-n series name] [-s] [-i] [-o NFODIR] filenames\n";
    exit;
} else {
    foreach $filename (@ARGV) {
        getInfo($filename) if -e $filename;
    }
} 

exit 0;

