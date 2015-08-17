#!/usr/bin/perl
# $Rev: 11 $
# $Author: pndiku $

use strict;
use warnings;
use LWP::Simple;
use TMDB;
use Date::Calc qw(Add_Delta_Days);
use Data::Dumper;
use Getopt::Std;
use Mediainfo;
use Path::Class;
use File::Basename;
use Video::FrameGrab;
use WWW::YouTube::Download;
use List::MoreUtils qw/ uniq /;
use JSON::Parse 'json_to_perl';
use WWW::Mechanize;
use XML::LibXML;
use File::Temp;
use Encode qw(encode decode);
use feature qw{ switch };

no warnings 'utf8';

# declare the perl command line flags/options we want to allow
my %options=();
getopts("cain:tf:d:o:", \%options);

my $num_args = $#ARGV + 1;
if ($num_args != 1) {
    print "\nUsage: movie.pl [-n name] filename [$num_args]\n";
    exit;
}

my $getimages = 0;
my $gettrailers = 0;
my $MOVIENAME;
my $counter = 0;
my $FILENAME = $ARGV[0];
my $auto = 0;
my $getfileinfo = 0;
my $getcollection = 0;

my $f = file($FILENAME);

my ($BASEDIR, $BASEFILENAME) = getBaseName($FILENAME);

$BASEFILENAME =~ s/:/\$3A/g;

my $OUTPUTDIR = $BASEDIR;

$getimages = 1 if defined $options{i};
$getcollection = 1 if defined $options{c};
$gettrailers = 1 if defined $options{t};
$auto = 1 if defined $options{a};
$getfileinfo = $options{f} if defined $options{f};
$OUTPUTDIR = $options{o} if defined $options{o};

my $IMDB_ID;
$IMDB_ID = $options{d} if defined $options{d};

$MOVIENAME = $f->absolute->parent->basename;

$MOVIENAME = $options{n} if defined $options{n};

shift;

my $tmdb_client = TMDB->new( apikey => 'MYAPI-KEY' );
my $youtube_client = WWW::YouTube::Download->new;

sub getDecodedValue {
    my ($myString) = @_;
    
    my $r;
    $r = eval { decode('UTF-8', $myString) } or $r = $myString;
    return $r;
}

sub getEncodedValue {
    my ($myString) = @_;
    
    my $r;
    $r = eval { encode('UTF-8', $myString) } or $r = $myString;
    return $r;
}

sub getCodec
{
    my $codec = $_[0];

    given (lc($codec)) {
	when(/ac-3/i) { return "AC3" }
    }
    return $codec;
}

sub _tohm
{
    my ($S) = @_;

    my $h = $S/60;
    my $m = $S%60;
    my $out = "";
    if ($h > 0) {
	$out = sprintf("%dh %02dm", $h, $m);
    } else {
	$out = sprintf("%02dm", $m);
    }
    return $out;
}


sub getBaseName
{
    my ($pfile) = @_;
    my ($name, $path, $suffix) = fileparse($pfile, '\.[^\.]*');

    return ($path, $name);
}

sub printCollectionNFO
{
    my ($collection) = @_;

    my $doc = XML::LibXML::Document->createDocument( "1.0", "UTF-8");
 
    my $root = $doc->createElement("movie");
    my ($node, $text, $NFO) = ();

    print STDERR "Generating Set NFO...\n";

    $doc->setDocumentElement($root);

    $node = $doc->createElement("id");
    $text = XML::LibXML::Text->new($collection->{id});
    $node->appendChild($text);
    $root->appendChild($node);

    $node = $doc->createElement("title");
    $text = XML::LibXML::Text->new($collection->{name});
    $node->appendChild($text);
    $root->appendChild($node);

    $node = $doc->createElement("plot");
    $text = XML::LibXML::Text->new($collection->{overview});
    $node->appendChild($text);
    $root->appendChild($node);

    my $COLLECTIONBASE = $collection->{name};
    $COLLECTIONBASE =~ s/:/\$3A/g;

    if ( $OUTPUTDIR eq "." ) {
	$NFO = "../Set_" . $COLLECTIONBASE . "_1.nfo";
    } else {
	$NFO = $OUTPUTDIR . "/Set_" . $COLLECTIONBASE . "_1.nfo";
    }

    $doc->toFile($NFO, 1);

    if ($getimages == 1) {
	my $POSTERFILE = "../Set_" . $COLLECTIONBASE . "_1.jpg";
	my $FANARTFILE = "../Set_" . $COLLECTIONBASE . "_1.fanart.jpg";

	# print Dumper $collection;
	if ($collection->{poster_path} ) {
	    print STDERR "Downloading Set poster [$POSTERFILE]\n";
	    LWP::Simple::getstore( "http://cf2.imgobject.com/t/p/original" . $collection->{poster_path}, $POSTERFILE) unless -e $POSTERFILE;
	}
	
	if ($collection->{backdrop_path} ) {
	    print STDERR "Downloading Set fanart [$FANARTFILE]\n";
	    LWP::Simple::getstore( "http://cf2.imgobject.com/t/p/original" . $collection->{backdrop_path}, $FANARTFILE) unless -e $FANARTFILE;
	}
    }
}

sub get_movie_id
{
    $MOVIENAME =~ s/^\d+. //g;
    print STDERR "Searching for movie '$MOVIENAME'\n"; 

    my @results = $tmdb_client->search->movie($MOVIENAME);
    my $choice = 1;
    my @ids;
    $counter = 1;

    if (scalar(@results) == 1 || $auto == 1) {
	push @ids, $results[0]->{id};
    }
    else {
	foreach my $result (@results) {
		printf(STDERR "%d.\t%s:\t%s (%s)\n",
		       $counter++,
		       $result->{id}, getEncodedValue($result->{title}),
		       split( /-/, $result->{release_date}, 1 ));
		push @ids, $result->{id};
	}
    }
    
    if (scalar(@ids) > 1) {
	print STDERR "Which movie? (0 to quit, ENTER to accept default): ";
	$choice = <>; 
	
	if ($choice == 0) {
	    print "QUIT";
	    exit;
	}
    } elsif (scalar(@ids) == 1) {
	print STDERR "Only 1 result, automatically proceeding\n";
	$choice = 1;
    } else {
	print STDERR "No results found...";
    }


    $choice = 1 unless $choice;
    return $ids[$choice-1];
}

sub get_movie_details
{
    my ($movie_id) = @_;

    print STDERR "NFO FILE: " . $OUTPUTDIR . "/" . $BASEFILENAME . ".nfo\n";

    print STDERR "Generating NFO...\n";
    # Movie Object
    my $movie = $tmdb_client->movie(id => $movie_id); 

    $IMDB_ID = $movie->imdb_id unless defined $IMDB_ID;

    my $json_url;
    my $browser;
    my $content;
    my $imdb;
    my $rating;
    my $votes;
    my $mpaa;
    my $plot;
    my $node;
    my $text;
    
    if ($IMDB_ID) {
	$json_url="http://omdbapi.com/?plot=full&i=" . $IMDB_ID;
	$browser = WWW::Mechanize->new();
	$browser->get( $json_url );
	$content = $browser->content();
	$imdb = json_to_perl($content);
	
	$rating = $imdb->{imdbRating};
	$rating =~ s#N/A##;
	$votes = $imdb->{imdbVotes};
	$mpaa = $imdb->{Rated};
#	$mpaa =~ s/_/\-/g if $mpaa;
	$plot = $imdb->{Plot};
    }

#    print Dumper $imdb;
#    print Dumper $movie->info;
#    exit;
#    print Dumper getDecodedValue($imdb->{Writer});

    my $in_collection =  $movie->info->{belongs_to_collection};

    my $top250_line = "";
    my $title = "";
    my $year = "";

    $title = $imdb->{Title} if $imdb->{Title};
    my $original_title = getEncodedValue($movie->info->{original_title}) || $movie->info->{title};
    $year = $imdb->{Year} if $imdb->{Year};
    $year = $movie->year if $movie->year;

    my $search_string = "\\($title.*($year)\\|$original_title.*($year)\\)";
    $search_string =~ s/\'/./g;

    $top250_line = `/usr/bin/grep -aiZn '$search_string' /data/imdb/lists/top250`;
    $top250_line =~ /^(\d+):/;

    my $top250 = $1 if $top250_line;
#    print STDERR "/usr/bin/grep -aiZn '$search_string' /data/imdb/lists/top250\n";
    print STDERR "Found movie in Top250: $1\n" if $top250_line;

    my ($y, $m, $d) = split( /\-/, $movie->info->{release_date} ) if $movie->info->{release_date};

    my $doc = XML::LibXML::Document->createDocument( "1.0", "UTF-8");
 
    my $root =  $doc->createElement("movie");
    $doc->setDocumentElement($root);
    $root->setAttribute("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance");
    $root->setAttribute("xmlns:xsd", "http://www.w3.org/2001/XMLSchema");

    if ($IMDB_ID) {
	my $id = $doc->createElement("id");
	$id->setAttribute("moviedb", "imdb");
	$text = XML::LibXML::Text->new($IMDB_ID);
	$id->appendChild($text);
	$root->appendChild($id);
    }
    if ($movie->title) {
	$node = $doc->createElement("title");
	$text = XML::LibXML::Text->new($movie->title);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($movie->info->{original_title}) {
	$node = $doc->createElement("originaltitle");
	$text = XML::LibXML::Text->new($movie->info->{original_title});
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($movie->year) {
	$node = $doc->createElement("year");
	$text = XML::LibXML::Text->new(sprintf "%.4s", $movie->year);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($movie->info->{release_date}) {
	$node = $doc->createElement("premiered");
	$text = XML::LibXML::Text->new(sprintf "%d-%02d-%02d", $y, $m, $d);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($top250) {
	$node = $doc->createElement("top250");
	$text = XML::LibXML::Text->new(sprintf "%d", $top250);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($rating) {
	$node = $doc->createElement("rating");
	$text = XML::LibXML::Text->new(sprintf "%.1f", $rating);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($votes) {
	$node = $doc->createElement("votes");
	$text = XML::LibXML::Text->new($votes);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    if ($mpaa) {
	$node = $doc->createElement("mpaa");
	$text = XML::LibXML::Text->new($mpaa);
	$node->appendChild($text);
	$root->appendChild($node);
    }
    
    foreach my $release ($movie->releases) {
	if ($release->{iso_3166_1} eq "US") {
	    $node = $doc->createElement("certification");
	    $text = XML::LibXML::Text->new($release->{certification});
	    $node->appendChild($text);
	    $root->appendChild($node);
	}
    }

    foreach my $genre ($movie->genres) {
	$node = $doc->createElement("genre");
	$text = XML::LibXML::Text->new($genre);
	$node->appendChild($text);
	$root->appendChild($node);
    }

    my $companies = $movie->info->{production_companies} if $movie->info->{production_companies};

    $counter = 0;
    my $choice = 0;

    if ($auto == 0) {
	if ( scalar(@{$companies}) > 1 ) {
	    
	    foreach my $company (@{$companies}){
		printf("%d.\t%s\n", $counter++, getEncodedValue($company->{name}));
	    }
	    print STDERR "Which company? [0]: ";
	    
	    my $choice = <>; 
	}
	$choice = 0 unless $choice;
    }
    
    if ( scalar(@{$companies}) > 0 ) {
        $node = $doc->createElement("company");
        $text = XML::LibXML::Text->new(@{$companies}[$choice]->{name});
        $node->appendChild($text);
        $root->appendChild($node);
    }
    
    foreach my $crew (@{$movie->crew}) {
        if ($crew->{job} eq "Director" ) {
            $node = $doc->createElement("director");
            $text = XML::LibXML::Text->new($crew->{name});
            $node->appendChild($text);
            $root->appendChild($node);
        }
    }
    
    my @writers;
    my $writer;
    my $w;

    my %seen   = ();
    foreach $writer (@{$movie->{writer}}){
        my @ws = split /[\|&,;]/, $writer;
        foreach $w (@ws) {
            $w =~ s/(^ | $| (X))//;
            $w =~ s/ \(.*\)//;
            next if $w eq "";
            my $d = lc($w);
            next if $seen{ $d }++;
            push @writers, $w;
        }
    }
    
    my @ws;
    @ws = split /[\|&,;]/, $imdb->{Writer} if $imdb->{Writer} ;
    foreach $w (@ws) {
        $w =~ s/(^ | $| (X))//;
        $w =~ s/ \(.*\)//;
        next if $w eq "";
        my $d = lc($w);
        next if $seen{ $d }++;
        push @writers, getDecodedValue($w);
    }
    
    foreach my $writer (@writers){
        $node = $doc->createElement("credits");
        $text = XML::LibXML::Text->new($writer);
        $node->appendChild($text);
        $root->appendChild($node);
    }
    
    if ($movie->tagline) {
        $node = $doc->createElement("tagline");
        $text = XML::LibXML::Text->new($movie->tagline);
        $node->appendChild($text);
        $root->appendChild($node);
    }
    if ($movie->overview) {
        $node = $doc->createElement("outline");
        $text = XML::LibXML::Text->new($movie->overview);
        $node->appendChild($text);
        $root->appendChild($node);
    }
    if ($plot) {
        $node = $doc->createElement("plot");
        $text = XML::LibXML::Text->new($plot);
        $node->appendChild($text);
        $root->appendChild($node);
    }
    if ($movie->info->{runtime}) {
        $node = $doc->createElement("runtime");
        $text = XML::LibXML::Text->new(_tohm($movie->info->{runtime}));
	$node->appendChild($text);
	$root->appendChild($node);
    }

    my @actors = $movie->cast();
    foreach my $actor (@actors){
	my $node_a = $doc->createElement("actor");

	$node = $doc->createElement("name");
	$text = XML::LibXML::Text->new($actor->{name});
	$node->appendChild($text);
	$node_a->appendChild($node);

	if ($actor->{character}) {
	    $node = $doc->createElement("role");
	    $text = XML::LibXML::Text->new($actor->{character});
	    $node->appendChild($text);
	    $node_a->appendChild($node);
	}

	if ($actor->{profile_path}) {
	    $node = $doc->createElement("thumb");
	    $text = XML::LibXML::Text->new("http://cf2.imgobject.com/t/p/original" . $actor->{profile_path});
	    $node->appendChild($text);
	    $node_a->appendChild($node);
	}
	$root->appendChild($node_a);
    }

    my $vidSource;

    if ($FILENAME =~ m/DVDSCR/i) {
	$vidSource = "DVDSCR";
    } elsif  ($FILENAME =~ m/HDDVD/i) {
	$vidSource = "HDDVD";
    } elsif  ($FILENAME =~ m/R5/i) {
	$vidSource = "R5";
    } elsif  ($FILENAME =~ m/(B[RD]Rip|BluRay)/i) {
	$vidSource = "BluRay";
    } elsif  ($FILENAME =~ m/DVD/i) {
	$vidSource = "DVD";
    } elsif  ($FILENAME =~ m/HDTV/i) {
	$vidSource = "HDTV";
    } elsif  ($FILENAME =~ m/\.CAM\./i) {
	$vidSource = "CAM";
    } elsif  ($FILENAME =~ m/\.TS\./i) {
	$vidSource = "TS";
    } elsif  ($FILENAME =~ m/WEB\-*DL/i) {
	$vidSource = "WEBDL";
    } else {
	$vidSource = "DVD";
    }

    $node = $doc->createElement("videosource");
    $text = XML::LibXML::Text->new($vidSource);
    $node->appendChild($text);
    $root->appendChild($node);

    if ($in_collection) {
	print "Found a collection with id $in_collection->{id}\n";
	my $collection = $tmdb_client->collection(id => $in_collection->{id});
	# print Dumper $collection->info;
	if ($getcollection == 1) {
	    printCollectionNFO($collection->info);
	}

	my @parts = @{$collection->info->{parts}};
	
	my @sorted =  sort { $a->{release_date} cmp $b->{release_date} } @parts;

	my $counter = 1;
	my $node_s = $doc->createElement("sets");
	foreach my $part (@sorted) {
	    if ($part->{id} == $movie->{id} ) {
		$node = $doc->createElement("set");
		$node->setAttribute("order", $counter);
		$text = XML::LibXML::Text->new($collection->info->{name});
		$node->appendChild($text);
		$node_s->appendChild($node);
	    }
	    $counter++;
	}
	$root->appendChild($node_s);
    }

    if ($getfileinfo == 1) {
	my $media_info = new Mediainfo(filename => $FILENAME);

	my $fileinfo = $doc->createElement("fileinfo");

	if ($media_info->{container}) {
	    $node = $doc->createElement("container");
	    $text = XML::LibXML::Text->new($media_info->{container});
	    $node->appendChild($text);
	    $fileinfo->appendChild($node);
	}

	my $streamdetails = $doc->createElement("streamdetails");

	my $audio = $doc->createElement("audio");

	$node = $doc->createElement("channels");
	$text = XML::LibXML::Text->new($media_info->{audio_channels});
	$node->appendChild($text);
	$audio->appendChild($node);

	$node = $doc->createElement("codec");
	$text = XML::LibXML::Text->new($media_info->{audio_format});
	$node->appendChild($text);
	$audio->appendChild($node);

	if ($media_info->{audio_language}) {
	    $node = $doc->createElement("language");
	    $text = XML::LibXML::Text->new($media_info->{audio_language});
	    $node->appendChild($text);
	    $audio->appendChild($node);
	}

	$streamdetails->appendChild($audio);

	my $video = $doc->createElement("video");

	$node = $doc->createElement("aspect");
	$text = XML::LibXML::Text->new($media_info->{dar});
	$node->appendChild($text);
	$video->appendChild($node);

	$node = $doc->createElement("codec");
	$text = XML::LibXML::Text->new($media_info->{video_format});
	$node->appendChild($text);
	$video->appendChild($node);

	$node = $doc->createElement("durationinseconds");
	$text = XML::LibXML::Text->new($media_info->{video_length});
	$node->appendChild($text);
	$video->appendChild($node);

	$node = $doc->createElement("height");
	$text = XML::LibXML::Text->new($media_info->{height});
	$node->appendChild($text);
	$video->appendChild($node);

	$node = $doc->createElement("width");
	$text = XML::LibXML::Text->new($media_info->{width});
	$node->appendChild($text);
	$video->appendChild($node);

	$streamdetails->appendChild($video);

	$fileinfo->appendChild($streamdetails);

	$root->appendChild($fileinfo);
    }

    # my ($fh, $file) = tmpnam();
    $doc->toFile($OUTPUTDIR . "/" . $BASEFILENAME . ".nfo", 1);
    # $doc->toFH($fh, 2);
    # system("/usr/bin/iconv -fUTF-8 -tUTF-8 '" . $file . "' -o \"" . $OUTPUTDIR . "/" . $BASEFILENAME . ".nfo\"");

    # What about images?
    # For now, put the main poster & fanart
    if ($getimages == 1) {
	mkdir "Images";
	my $POSTERFILE = $BASEDIR . "Images/" . $BASEFILENAME . ".jpg";
	my $BANNERFILE = $BASEDIR . "Images/" . $BASEFILENAME . ".banner.jpg";
	my $FANARTFILE = $BASEDIR . "Images/" . $BASEFILENAME . ".fanart.jpg";
	
	print STDERR "Downloading poster\n";
	LWP::Simple::getstore( "http://cf2.imgobject.com/t/p/original" . $movie->poster, $POSTERFILE) unless -e $POSTERFILE;
	
	if ( $movie->backdrop ) {
	    print STDERR "Downloading fanart\n";
	    LWP::Simple::getstore( "http://cf2.imgobject.com/t/p/original" . $movie->backdrop, $FANARTFILE) unless -e $FANARTFILE;

#	} else {
#	    if (! -e $FANARTFILE ) {
#		print STDERR "Generating fanart image for movie\n";
#		my $grabber = Video::FrameGrab->new( video => $FILENAME );
#		my $jpg_data = $grabber->snap( "00:30:00" );
#		$grabber->jpeg_save($FANARTFILE) unless -e $FANARTFILE;
#	    }
	}

    }

    if ($gettrailers == 1) {
	$counter = 1;
	my @trailers = uniq @{$movie->trailers_youtube};
	print STDERR scalar(@trailers) . " trailer(s) to download...\n";
	my $id;
	foreach my $trailer (@trailers){
	    $trailer =~ /http:\/\/youtu.be\/(.*)/;
	    my $id = $1;
	    print STDERR "Downloading trailer $counter [$id]\n";
	    my $OUTFILE = $BASEDIR . $BASEFILENAME . "[Trailer ". $counter++ . "]";
	    system("/usr/bin/youtube-dl --proxy \"\" --merge-output-format mkv -o \"" . $OUTFILE . ".%(ext)s\" \"http://youtube.com/v/".$id."\"") if (! -e "$OUTFILE.flv" and ! -e "$OUTFILE.mp4" and ! -e "$OUTFILE.mkv" );

	}
    }

}

my $id = get_movie_id();

if ($id) {
    print STDERR "Found ID [$id]\n";
    
    #Now get the movie details, print to NFO and optionally download images
    get_movie_details($id) if $id;
}
