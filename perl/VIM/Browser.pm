# File Name: Browser.pm
# Maintainer: Moshe Kaminsky <kaminsky@math.huji.ac.il>
# Last Update: September 03, 2004
###########################################################

############# description of this module ##################
# This module contains most of the implementation of the vim browser plugin.  
# The broad structure is like this:
# 
# * VIM::Browser - This is the main module that controls the overall 
# operation. It is also the only 'public' part: it is the only part used 
# directly in the browser.vim plugin.
#
# * VIM::Browser::Page - A class that represents a web page, or, more 
# generally, the contents of a location. Usually has a buffer associated to 
# it, but the buffer might be hidden.
#
# * VIM::Browser::Window - A class representing a browser window or tab.  
# Loosely corresponds to a vim window. Each such window generally has a Page 
# object associated to it (but the same Page may be associated to more than 
# one window).
#
# * VIM::Browser::AddrBook - A class representing a bookmark file, and 
# provides hash access to it.
#
# More detailed description follows below.
##########################################################

###################### bookmark files ####################
# The following class provides access to bookmark files. A hash tied to this 
# class has nicknames as keys. The value for each key is a two element array 
# ref, the first element being the uri, and the second is a description 
# (usually the contents of the 'title' header field for that uri)
package VIM::Browser::AddrBook;
use base 'Tie::Hash';

sub TIEHASH {
    my $class = shift;
    my $self = { file => shift };
    if ( -r $self->{'file'} ) {
        unless ( open FH, $self->{'file'} ) {
            Vim::error("Failed to open $self->{'file'} for reading");
            return undef;
        }
        local $_;
        while ( <FH> ) {
            next if /^#/o;
            $self->{'mark'}{$1} = [$2, $3] if /^(\w+)\s+(\S+)\s*(.*)$/o;
        }
        close FH;
    }
    bless $self => $class;
}

# re-create the bookmarks file (destroying any prior info)
sub update {
    my $self = shift;
    unless ( open FH, '>' , $self->{'file'} ) { 
        Vim::error("failed to write to $self->{'file'}");
        return undef;
    }
    print FH "$_ $self->{'mark'}{$_}[0] $self->{'mark'}{$_}[1]\n"
        foreach keys %{$self->{'mark'}};
    close FH;
    1;
}

# print the bookmarks
sub list {
    my $self = shift;
    VIM::Msg("Bookmarks in $self->{'file'}", 'Type');
    VIM::Msg("$_: $self->{'mark'}{$_}[0] # $self->{'mark'}{$_}[1]")
        foreach keys %{$self->{'mark'}};
}

# the tying routines. Most just do the hash operations on the $self->{'mark'} 
# hash, updating the file when necessary.
sub STORE {
    my ($self, $key, $value) = @_;
    if ( $self->EXISTS($key) ) {
        $self->{'mark'}{$key} = $value;
        $self->update();
    } else {
        # if the key is new, add only it to the bookmark file, thus retaining 
        # any comments
        unless ( open FH, '>>' , $self->{'file'} ) { 
            Vim::error("failed to write to $self->{'file'}");
            return undef;
        }
        print FH "$key $value->[0] $value->[1]\n";
        close FH;
        $self->{'mark'}{$key} = $value;
    }
}

sub FETCH {
    $_[0]->{'mark'}{$_[1]};
}

sub FIRSTKEY {
    my $self = shift;
    my $a = keys %{$self->{'mark'}};
    each %{$self->{'mark'}};
}

sub NEXTKEY {
    each %{ $_[0]->{'mark'} };
}

sub EXISTS {
    exists $_[0]->{'mark'}{$_[1]};
}

sub DELETE {
    delete $_[0]->{'mark'}{$_[1]};
    $_[0]->update();
}

sub CLEAR {
    $_[0]->{'mark'} = {};
    $_[0]->update();
}

sub SCALAR {
    scalar %{$_[0]->{'mark'}};
}

###################### web pages ############################
# VIM::Browser::Page represents one web page. Since most of the work is web 
# page related, this is where it is done.
#############################################################
package VIM::Browser::Page;
use overload '""' => 'as_string';
use HTML::FormatText::Vim;
use HTML::Form;
use Encode;
use URI;
use Vim;
use Data::Dumper;

# the following hash contains the default action to take after loading a 
# given content type. The keys are the content types. The value is 
# interpreted as follows:
#
# - if the value is a code ref, it is taken to be a function for scanning and 
# formatting the source text. It should return a list of lines, which will be 
# put in the buffer without modification. In addition, the should set the 
# 'type' field of $self to the vim filetype corresponding to the source (if 
# there is such a type). They should also set, if possible, the 'links' and 
# the 'fragment' fields (see below for their meaning). The only argument to 
# the function is the Page object itself, with all the fields (except those 
# that should be filled by the function) filled in.
#
# - otherwise, it should be a string, that denotes an action to take.  
# Currently the only strings supported are 'del', which means that this 
# location is invalid, and 'save', which means to save the contents to a 
# file. 'save' is also the default action, if the key for the given content 
# type does not exist. The action will be available in the action field. If 
# the value is a code ref, the value of the action field will be 'show'.

our %FORMAT = (
    'text/html' => sub {
        my $self = shift;
        $self->type = 'html';
        my $width = $Vim::Option{'textwidth'};
        $width = $Vim::Option{'columns'} - $Vim::Option{'wrapmargin'} 
            unless $width;
        my $encoding = $self->header('encoding');
        my $html = 
            Encode::resolve_alias($encoding) ? decode($encoding, $self->source)
                                             : $self->source;
        my $base = $self->header('uri base');
        my @forms = HTML::Form->parse($html, $base);
        my $formatter = new HTML::FormatText::Vim 
            leftmargin => 0, 
            rightmargin => $width,
            # the formatter will store the absolute uris for the links using 
            # this base
            base => $base,
            # the forms of this page
            forms => [ @forms ],
            # the decoration to use for various tags. The possible tags are 
            # stored in the %Markup hash in HTML::FormatText::Vim
            map { 
                +"${_}_start" => $Vim::Variable{"g:browser_${_}_start"},
                "${_}_end" => $Vim::Variable{"g:browser_${_}_end"} 
            } grep {
                # take only those that were defined by the user. The other 
                # ones will have defaults
                exists $Vim::Variable{"g:browser_${_}_start"} 
            } keys %HTML::FormatText::Vim::Markup;
        my $text = $formatter->format_string($html);
        # TODO find out what's with the encoding
        #x     my $vimEncoding = VIM::Eval('&encoding');
        #x     $text = encode($vimEncoding, $text);
        $self->links = $formatter->{'links'};
        $self->fragment = $formatter->{'fragment'};
        @Res = split "\n", $text;
    },
    'text/plain' => sub {
        # do nothing special
        split "\n", shift->source;
    }
);

# arguments for construction: after the class name we have the uri, and the 
# rest of the arguments are passed to format() after the response.
sub new {
    my $class = shift;
    my $req = shift;
    ### Fields of a Page: unless mentioned otherwise, fields are usually
    # initialized by the 'format' method. 'the formatter' means the element 
    # of %FORMAT corresponding to the content type
    my $self = {
        # title of the document
        title => undef,
        # the buffer object associated to this page. Initialized by the 
        # 'show' method
        buffer => undef,
        # number of extra lines in the top of the buffer, not taken account 
        # in the lines of the links and fragments (due to the addition of 
        # headers)
        offset => 0,
        # a hash ref, containing various head fields. The most important ones 
        # are 'encoding', 'content type' and 'uri base'.
        header => undef,
        # a hash ref, containing for each fragment (aka anchor, the name= 
        # argument of an 'a' tag) the line number in the buffer where it 
        # occurs. Line numbers here and in the links field below start from 
        # 0.
        # Initialized by the formatter.
        fragment => undef,
        # an array ref, containing, for a number n, the list of links that 
        # occur on line n. Each value is an array ref, each of whose elements 
        # is a hash ref with (at least) the fields 'from' and 'to', 
        # containing the link start and end columns, resp. Form inputs are 
        # also members of these list. If an element contains a field 
        # 'target', it is considered that this link can be followed, and the 
        # value of 'target' is either the destination, or a sub that can be 
        # called with $self, and returns the destination (any legal value for 
        # VIM::Browser::Window::openUri).
        # The form input links are designed as follows: First, there is an 
        # item for every physical entity in the page text. Thus, in contrast 
        # to HTML::Form inputs, there is a distinct item for each radio 
        # button. They generally have 3 fields pointing to subs: 'getval' 
        # gets the value of the input as reflected in the page text (gets the 
        # page as an argument), 'setval' sets the value of the input in the 
        # page (gets the page, and the new value), and 'update' updates the 
        # corresponding input object (from HTML::Form) from the value in the 
        # page (gets the page). The form is stored in the 'form' field, and 
        # the input is stored in the 'input' field.
        # Initialized by the formatter.
        links => undef,
        # the raw list of bytes retrieved from the location
        source => undef,
        # the vim file type corresponding to the source. Initialized by the 
        # formatter.
        type => undef,
        # what are we doing with this data (by default). A special value is 
        # 'show', which means we are just displaying the formatted contents 
        # in a buffer.
        action => undef,
        # a uri for this page (but note that more than one uri may lead to 
        # the same page due to redirection). Initialized by the 'fetch' 
        # method.
        uri => undef
    };
    bless $self, $class;
    Vim::debug("Creating a new page for $req");
    my $response = $self->fetch($req);
    # return undef unless $response->is_success;
    my @text = $self->format($response, @_);
    # if the action is 'show', we do it right now, with the given text
    my $keep = $self->action eq 'show' ? $self->show(@text) : 0;
    return undef unless $keep;
    # we might have been redirected - keep the other name an alias to 
    # this object
    my $request_uri = $self->uri;
    $VIM::Browser::URI{"$request_uri"} = $self;
    return $self;
}

# provide easy access to the fields

# hashes
for my $field (qw(header fragment)) {
    *$field = sub : lvalue {
        my $self = shift;
        @_ ? ( $self->{"$field"}{"@_"} ) : ( $self->{"$field"} );
    };
};

# arrays
for my $field (qw(links)) {
    *$field = sub : lvalue {
        my $self = shift;
        @_ ? $self->{"$field"}[shift] : $self->{"$field"};
    };
};

# scalars
for my $field (qw(action type title source offset uri buffer)) {
    *$field = sub : lvalue {
        $_[0]->{$field};
    };
};
 
sub as_string {
    my $res = $_[0]->{'uri'};
    $res =~ s/([?:%#])/\\$1/go;
    $res
}

# the various actions: to implement an action, define a method by the same 
# name. Arguments (except for $self) are action specific

# the show method. Arguments are the text lines, as should be put in the 
# buffer
sub show {
    my $self = shift;
    if ( @_ ) {
        if ( $self->buffer ) {
            Vim::debug(
                'Using existing buffer ' . $self->Name . ' for ' . $self->uri);
            $self->Delete(1, $self->Count);
        } else {
            Vim::debug('Creating a new buffer for ' . $self->uri);
            # This is a bit wrong because (theoretically) a file with the 
            # given name could exist
#x             VIM::DoCommand(
#x                 "silent edit +setfiletype\\ browser VimBrowser:-$self-");
            VIM::DoCommand('silent enew');
            VIM::DoCommand('setfiletype browser');
            VIM::DoCommand("silent! file VimBrowser:-$self-");
            # for some reason, an extra buffer is created, wipe it out
            VIM::DoCommand('bwipeout #');
            $self->buffer = $main::curbuf;
        }
        $self->Append(0, @_);
        return 1;
    } else {
        # there is no text, for some reason
        Vim::warning('Document contains no data');
        return 0;
    }
}

# save the content to a file. An optional argument is the file name. If not 
# given, we prompt the user.
sub save {
    my $self = shift;
    my $file;
    if ( @_ ) {
        $file = shift;
    }
    $file = Vim::ask('Save to file: ') unless $file;
    return 0 unless $file;
    # TODO: check if the file exists
    unless ( open FH, '>', $file ) {
        Vim::error("Unable to open $file for writing");
        return 0;
    }
    print FH $self->source;
    close FH;
    return 1;
}

# nothing special for the del action, since we remove any page whose action 
# is not 'show'
sub del { 1 }

# perform a given action on this page. Arguments are the action, and any 
# extra args specific for the given action. If the action is missing or 
# false, use the default $self->action
sub doAction {
    my $self = shift;
    my $action = @_ ? shift : $self->action;
    $action = $self->action unless $action;
    my $sub = sub { $self->$action(@_) };
    &$sub(@_);
}

# fill in all the fields for this page, fetching it if needed, and then call 
# the formatter if it is given (ie, the action is 'show'). Arguments are the 
# response object and the action. If the response object is false or missing, 
# the page is fetched. If the action is missing or false, it is determined, 
# using the content type of the response, from the %FORMAT hash. The return 
# value is the list of lines to display if the action is 'show', and the 
# empty list otherwise.
sub format {
    my $self = shift;
    my $response = @_ ? shift : $self->fetch;
    $response = $self->fetch unless $response;
    #unless ($response->is_success) {
    #    $self->action = 'del';
    #    return ();
    #}
    my $encoding = $response->content_encoding;
    unless ($encoding) {
        foreach ($response->header('content-type')) {
            if ( /charset=(\S*)/ ) {
                $encoding = $1;
                last;
            }
        }
    }
    unless ($encoding) {
        $encoding = $VIM::Browser::AssumedEncoding;
        Vim::warning("Unable to get page encoding, assuming $encoding");
    }
    $self->source = $response->content;
    $self->header = { 
        'expires' => scalar(localtime($response->expires)),
        'last modified' => scalar(localtime($response->last_modified)),
        'content type' => scalar $response->content_type,
        'encoding' => $encoding,
        'language' => scalar $response->content_language,
        'server' => scalar $response->server,
        'keywords' => scalar $response->header('X-Meta-Keywords'),
        'description' => scalar $response->header('X-Meta-Description')
    };
    delete $self->header->{$_} 
        foreach grep { not $self->header($_) } keys %{$self->header};
    my $base = $response->base;
    # try to make it absolute
    $base = URI::file->new_abs($base->file) if $base->scheme eq 'file';
    $self->header('uri base') = $base;
    $self->title = $response->title;
    my $handler = @_ ? shift : $FORMAT{$response->content_type()};
    # default default action is to save
    $handler = 'save' unless $handler;
    if ( ref($handler) eq 'CODE' ) {
        # we are to format and display the content
        $self->action = 'show';
        return &$handler($self);
    } else {
        $self->action = $handler;
        return ();
    }
}

# fetch the page, and return the raw response object
# we also update the 'uri' field here.
sub fetch {
    my $self = shift;
    my $response = VIM::Browser::fetch(@_ ? shift : $self->uri);
    $self->uri = $response->request->uri;
    $response
}

# return the line of a given anchor name
sub fragmentLine {
    my $self = shift;
    my $fragment = shift;
    my $fragments = $self->fragment;
    # for some reason we need to add 4 (TODO)
    return $fragments->{$fragment} + $self->offset + 4;
}

## The document header, showing and removing

sub addHeader {
    my $self = shift;
    return if $self->offset;
    my $header = $self->header;
    my @lines = ( sprintf('%s {{{', 
            $self->title ? $self->title : 'Document header') ) ;
    push @lines, "  $_: " . $header->{$_} foreach keys %$header;
    push @lines, "}}}", '';
    @lines = ($self->title ? ( $self->title ) : ()) if ( scalar(@line) == 2 );
    $self->Append(0, @lines);
    $self->offset = scalar(@lines);
}

sub removeHeader {
    my $self = shift;
    my $Offset = $self->offset;
    $self->Delete(1, $Offset) if $Offset;
    $self->offset = 0;
}

# get the line with the given number, not including the header. Line numbers
# start from 1
sub getLine {
    my ($self, $line) = @_;
    my $Offset = $self->offset;
    $self->buffer->Get($line - $Offset + 1);
}

# set the line with the given number, not including the header, to the given
# value. Line numbers start from 1
sub setLine {
    my ($self, $line, $value) = @_;
    my $Offset = $self->offset;
    $self->buffer->Set($line - $Offset + 1, $value);
}

# return the link in the current cursor location, or undef if there is no 
# return the link in the current cursor location, or undef if there is no 
# link. The returned object is the corresponding hashref in the 'links' 
# field.
sub findLink {
    my $self = shift;
    my ($row, $col) = $main::curwin->Cursor;
    $row -= $self->offset;
    # no links in the header
    return undef if $row < 1;
    my $links = $self->links($row-1);
    my @links = grep { $col >= $_->{'from'} and $col <= $_->{'to'} } @$links;
    shift @links || undef;
}

# find the next/prev link. Arguments are the direction (1 for next, -1 for 
# prev), and coordinate as returned by the Cursor method of the vim buffer.  
# Returns the hashref corresponding to the link in the 'links' field, and the 
# line offset from the given line where the link appears (so the link will be 
# on line $row+$offset, where $offset is this offset.
sub findNextLink {
    my ($self, $dir, $row, $col) = @_;
    $row -= ($self->offset + 1);
    # we might have been in the header - $offset will compensate for that
    my $offset = 0;
    if ( $row < 0 ) {
        return undef if $dir < 0;
        $offset = $row;
        $row = $col = 0;
    }
    # try first in the current line
    my $links = $self->links($row);
    if ( $dir > 0 ) {
        my @links = grep { $_->{'from'} > $col } @$links;
        return (shift(@links), -$offset) if @links;
    } else {
        my @links = grep { $_->{'to'} < $col } @$links;
        return (pop(@links), 0) if @links;
    }
    # if we got here, no match in the current line
    $links = [];
    # $limit-$nrow is the current line we are searching
    my $nrow = $dir * $row;
    my $limit = $dir < 0 ? 0 : $self->Count() - 1;
    while ( ++$nrow <= $limit ) {
        $links = $self->links($dir * $nrow);
        last if @$links;
    }
    return undef unless @$links;
    return $dir < 0 ? ( $links->[-1], -($nrow + $row) ) 
                    : ( $links->[0], $nrow - $row - $offset );
}

# display the link target
sub linkTarget {
    my $self = shift;
    my $link = shift;
    (ref $link->{'target'}) ? &{$link->{'target'}}($self)
                            : $link->{'target'};
}

# display the raw source in a scratch buffer
sub viewSource {
    my ($self, $Cmd) = @_;
    VIM::DoCommand($Cmd);
    VIM::DoCommand('setfiletype ' . $self->type ) if $self->type;
    $Vim::Option{'buftype'} = 'nofile';
    $Vim::Option{'buflisted'} = 0;
    $Vim::Option{'swapfile'} = 0;
    $main::curbuf->Append(0, split "\n", $self->source);
}

# shortcut to call methods of the associated buffer, as if they were our
sub AUTOLOAD {
    return if our $AUTOLOAD =~ /::DESTROY$/o;
    return unless $AUTOLOAD =~ /^[A-Z]/o;
    my $self = shift;
    $AUTOLOAD =~ s/^(\w+::)*//o;
    $AUTOLOAD = ref($self->buffer) . "::$AUTOLOAD";
    unshift @_, $self->buffer;
    goto &$AUTOLOAD;
}

## The window class represents a browser window, and (loosely) a vim window.  
#
# It should be destroyed when the window is closed. Thus, each window that 
# contains a browser, has a variable w:browserId, which enables us to find 
# the Window object associated to it.
package VIM::Browser::Window;
use overload '""' => 'as_string';
use URI;
use Vim;

# we have two argument when construction: the vim command to open a window 
# for this object (either 'new' or 'vnew'), and this window's id.
sub new {
    my ($class, $Cmd, $Id) = @_;
    ### Fields of a Window:
    my $self = { 
        # the id stored in the w:browserId vim variable
        id => $Id, 
        # the history list for this window
        back => [],
        # the future list for this window (the pages that come up with the 
        # Forward command)
        forward => [],
        # the fragment in the page where this window currently is
        fragment => undef,
        # the Page object whose contents we are displaying
        page => undef,
    };
    VIM::DoCommand($Cmd);
    $Vim::Variable{'w:browserId'} = $Id;
    bless $self => $class;
}

# method access to the fields

# scalars
for my $field (qw(page fragment id)) {
    *$field = sub : lvalue {
        $_[0]->{$field};
    }
}

# arrays
for my $field (qw(back forward)) {
    *$field = sub : lvalue {
        my $self = shift;
        @_ ? $self->{$field}[shift] : $self->{$field};
    };
}

# the string representation includes the fragment
sub as_string {
    my $self = shift;
    my $uri = $self->page->uri->clone;
    $uri->fragment($self->fragment);
    $uri;
}

# the line number of the current fragment
sub fragmentLine {
    my $self = shift;
    $self->page->fragmentLine($self->fragment);
}

# open a location in the current Window. Args are the uri, and possibly an 
# action. If an action is given, any extra arguments are passed to the action 
# implementor. If an action is not given, we assume the default action, 
# possibly using an existing Page instead of creating a new one. Returns 1 if 
# the page is displayed in the window, 0 otherwise
# The "uri" can, in fact, be one of 3 things:
# 1. A uri string
# 2. A URI object
# 3. An HTTP:Request object (which makes the name somewhat misleading...)
sub openUri {
    my $self = shift;
    my $uri = shift;
    $uri = new URI $uri unless ref($uri);
    Vim::debug("Opening $uri");
    if ( @_ ) {
        # we are given an action
        $Page = new VIM::Browser::Page $uri, shift;
    } else {
        # use cache, or default action to open
        $Page = $uri->isa('URI') ? $VIM::Browser::URI{"$uri"}
                                 : new VIM::Browser::Page $uri;
    }
    return 0 unless $Page;
    if ( $Page->action eq 'show' ) {
        # we are displaying the page
        # open the buffer of the page
        VIM::DoCommand("buffer " . $Page->Number);
        $self->page = $Page;
        # go to the right fragment
        my $fragment = $Page->uri->fragment(undef);
        $self->fragment = $fragment;
        VIM::DoCommand($self->fragmentLine);
        return 1;
    } else {
        # we are doing something else, run the action with the given 
        # arguments
        $Page->doAction(undef, @_);
        # we don't want to keep the page in this case
        # TODO: perhaps keep the page, conditionally on the size, etc.
        delete $VIM::Browser::URI{"$uri"} unless @_;
        return 0;
    }
}

# same as openUri, but keep the current page in the history
sub openNew {
    my $self = shift;
    push @{$self->back}, "$self" if $self->page;
    return $self->openUri(@_);
    
}

# get the link target of the given link, or the one at the current cursor 
# position if not given
sub getLink {
    my $self = shift;
    my $link = shift || $self->page->findLink;
    my $req = $self->page->linkTarget($link);
    return (ref($req) and $req->can('uri')) ? $req->uri : $req;
}

## history stuff

# show the history
sub showHist {
    my $self = shift;
    VIM::Msg("   $_") foreach reverse @{$self->forward};
    VIM::Msg("-> $self", 'Type');
    VIM::Msg("   $_") foreach reverse @{$self->back};
}

# go back/forward in this Window's history. Argument is the number of history 
# elements. Each of the history lists (back, forward) is treated as a stack.
sub goHist {
    my ($self, $Offset) = @_;
    my ($dir, $otherdir) = qw(forward back);
    if ( $Offset < 0 ) {
        ($dir, $otherdir) = qw(back forward);
        $Offset = -$Offset;
    }
    if ( @{$self->{$dir}} < $Offset ) {
        Vim::error("Can't go $Offset $dir in this window");
        return 0;
    }
    $Offset--;
    push @{$self->{$otherdir}}, 
        "$self", reverse(splice(@{$self->{$dir}}, -$Offset, $Offset));
    $self->openUri(pop @{$self->{$dir}});
}

############# The main package #################
package VIM::Browser;

use LWP::UserAgent;
use URI;
use URI::Heuristic qw(uf_uri);
use URI::file;
use Tie::Memoize;

use Data::Dumper;
use File::Spec::Functions qw(:ALL);
use File::Basename;
use File::Path;
use File::Glob ':glob';

use Vim;

use warnings;
use integer;

BEGIN {
    our $VERSION = 0.2;
}

# get the value of the given setting. Looks a variable g:browser_<foo>.  
# Returns a default value if not found
sub setting {
    my $var = 'g:browser_' . shift;
    return exists $Vim::Variable{$var} ? $Vim::Variable{$var} : shift;
}

# the hash of all Pages. Keys are absolute uris. If a non existing page is 
# requested, it is created.
tie our %URI, 'Tie::Memoize', sub { new VIM::Browser::Page shift || () };

# a hash associating browser window ids to Window objects
our $Browser = {};
# the current Window object
our $CurWin;
# the current window id
our $MaxWin = 0;

# This is totally stupid, but it appears there is no simple way to get the 
# file seperator for the current os.
our $FileSep = catdir('foo', 'bar');
# I hope no os uses foo or bar as the curdir :-)
$FileSep =~ s/^foo(.*)bar$/$1/o;

# the directory containing all bookmark files. Each file in this directory is 
# considered to be a bookmark file.
our @RunTimePath = grep { -w } split /,/, $Vim::Option{'runtimepath'};
our $DataDir = 
    canonpath(setting('data_dir', catdir(shift @RunTimePath, 'browser')));
our $AddressBookDir = 
    canonpath(setting('addrbook_dir', catdir($DataDir, 'addressbooks')));

$AddressBookDir .= $FileSep if $AddressBookDir;

#skip the whole bookmarks business if the directory is empty
if ( $AddressBookDir ) {
    die "Bookmarks directory must be absolute, not $AddressBookDir"
        unless file_name_is_absolute($AddressBookDir);

# make sure it exists
    if ( -d $AddressBookDir ) {
        die "$AddressBookDir is not readable" unless -r _;
    } elsif ( -e _ ) {
        die "$AddressBookDir exists, but is not a directory";
    } else {
        Vim::msg(
            "Bookmarks directory $AddressBookDir doesn't exist, creating...");
        mkpath($AddressBookDir, 0, 0755);
    }

# the hash of all bookmark files. Each entry is a hash tied to AddrBook, and 
# the keys are the names of the files (relative to $AddressBookDir)
    tie our %AddrBook, 'Tie::Memoize', sub { 
        my ($file, $dir) = @_;
        tie my %book, 'VIM::Browser::AddrBook', catfile($dir, $file);
        return \%book;
    }, $AddressBookDir, sub { -r catfile(reverse @_) };

# the current (default) bookmark file
    our $CurrentBook = setting('default_addrbook', 'default');
}

# the encoding we assume, if none is given in the document header
our $AssumedEncoding = setting('assumed_encoding', 'utf-8');

# cookies file
our $CookiesFile = setting('cookies_file', 
                           catfile($DataDir, 'cookies.txt'));
# the user agent
our $Agent = new LWP::UserAgent
    agent => "VimBrowser/$VERSION ",
    from => setting('from_header', $ENV{'EMAIL'}),
    protocols_forbidden => [qw(mailto)],
    cookie_jar => $CookiesFile ? { file => $CookiesFile, autosave => 1 } 
                               : undef,
    env_proxy => 1;

# scan all windows until we find:
# a. preferably the window corresponding to the current Window object
# b. otherwise, some browser window.
#
# In the second case, if a current window was defined, we remove it and set 
# the found window to be the current. If we found any browser window, the 
# situation will be that $CurWin is the Window object corresponding to the 
# window we found, and the cursor is in that window. The return value will be 
# $CurWin. Otherwise, we return 0
sub goBrowser {
    my ($success, $Id);
    my $CurId = $CurWin ? $CurWin->id : undef;
    # the criterion for finding the window
    my $found = $CurId ? sub { shift == $CurId } : sub { 1 };
    foreach (VIM::Windows) {
        if (defined ($Id = $Vim::Variable{'w:browserId'})) {
            $success = 1;
            last if &$found($Id);
        }
        VIM::DoCommand('wincmd W');
    }
    return 0 unless $success;
    # if we got here, we found _some_ window. Return it if it's the current 
    # one, or if the current wasn't specified
    return($CurWin = $Browser->{$Id}) if &$found($Id);
    # if we got here, we found some window, but the $CurWin no longer has a 
    # window. Destroy all trace of $CurWin, and start over, searching for any 
    # browser window whatsoever.
    delete $Browser->{$CurId};
    undef $CurWin;
    return goBrowser();
}

# return the given Page object, or, if not given, find a browser and return 
# its Page.
sub getPage {
    return shift if @_;
    unless (goBrowser) {
        Vim::error('Unable to find an open browser window');
        return;
    }
    return $CurWin->page;
}

# fetch a uri/request
sub fetch {
    my $req = shift;
    my ($uri, $response);
    if ( not ref($req) or $req->isa('URI') ) {
        $uri = $req;
        Vim::msg("Fetching $uri...");
        $response = $Agent->get($uri);
    } else {
        $uri = $req->uri;
        Vim::msg("Sending request to $uri...");
        $response = $Agent->request($req);
    }
    # the following status means that we are redirected, but UserAgent
    # doesn't do it automatically, for some reason. (TODO)
    return fetch( $response->headers->header('location') ) 
        if $response->status_line =~ /302 Found/;
    Vim::error("Failed to fetch $uri:", $response->status_line)
        unless ($response->is_success);
    return $response;
}

# get a partial uri or a bookmark, and return the canonical absolute uri.  
# This operates recursively so we may have bookmarks pointing to other 
# bookmarks, etc. The other arguments are interpreted as arguments: They are 
# concatenated after the uri, with + or & in front, depending on whether they 
# contain a '='.
sub canonical {
    local $_ = shift;
    if (@_) {
        my $uri = canonical($_);
        return undef unless defined $uri;
        $uri .= shift;
        $uri .= ((/\=/ ? '&' : '+') . $_) while $_ = shift;
        return new URI $uri;
    };
    # if this is _not_ a bookmark request, return the absolute uri
    return uf_uri($_) unless s/^://o;
    # if we got here, it's a bookmark - determine the bookmark file, and 
    # remove it from the request
    return undef unless $AddressBookDir;
    my $book = s/^([^:]*)://o ? $1 : $CurrentBook;
    $book = $CurrentBook unless $book;
    unless (exists $AddrBook{$book}) {
        Vim::error("Bookmark file $book does not exist (in $AddressBookDir)");
        return undef;
    };
    if (exists $AddrBook{$book}->{$_}) {
        return canonical($AddrBook{$book}->{$_}[0]);
    } else {
        Vim::error("Entry '$_' does not exists in bookmark file '$book'");
        return undef;
    }
}

# given a canonical uri, determine how to handle it, according to the scheme.
# If the variable g:browser_<scheme>_handler is defined, we use it to launch 
# the required handler, and return undef. Otherwise, the uri is returned, and 
# is handled internally, assuming it is supported.
sub checkScheme {
    my $uri = shift;
    $uri = new URI $uri unless ref $uri;
    return $uri unless $uri->isa('URI');
    my $scheme = $uri->scheme;
    unless ( defined $scheme ) {
        Vim::error(<<EOF);
Unable to determine the scheme of '$uri'.
Please try a more detailed uri.
EOF
        return undef;
    };
    my $handler = setting("${scheme}_handler");
    if ( $handler ) {
        $handler =~ s/%s/$uri/o;
        Vim::msg("Launching: '$handler'");
        system $handler;
        return undef;
    } elsif ( $Agent->is_protocol_supported($uri) ) {
        return $uri;
    } else {
        Vim::error(<<EOF);
The '$scheme' scheme is not supported.
Define g:browser_${scheme}_handler to add external support
EOF
        return undef;
    }
}

# return the list of files in the given directory. If the directory is not 
# given, use '.'. If the second argument is true, add a trailing slash to
# directory names
sub listDirFiles {
    my ($dir, $trailing) = @_;
    # uf_uri doesn't guess correctly for bare filenames without path
    # components. We will adopt this behaviour.
    return () unless $dir;
    # catfile (and catdir) on windows make the drive letter upper case -
    # don't use it!
    $dir .= '*';
    # $dir = $dir ? catfile($dir, "*") : "*";
    $flags = GLOB_TILDE; # | GLOB_NOSORT;
    $flags |= GLOB_MARK if $trailing;
    @res = bsd_glob($dir, $flags);
    map { s{/$}{$FileSep}o } @res if $trailing;
    return @res;
}

######################################################
#                   public area                      #
# These are functions used by the browser.vim plugin #
######################################################
# The current window is the one we're in, if it is a browser window.  
# Otherwise, it's the last browser window we've been to.
sub winChanged {
    my $id = $Vim::Variable{'w:browserId'};
    $CurWin = $Browser->{$id} if defined $id;
}
 
# remove the page with the given buffer name from the system
sub cleanBuf {
    local $_ = shift;
    return unless s/^VimBrowser:-(.*)-$/$1/o;
    delete $URI{$_};
}

# show the target of the link (given, or under the cursor)
sub showLinkTarget {
    # (TODO) This funny arrangement is used because the 'T' flag in 
    # 'shortmess' is not always in effect, for some reason. It works only 
    # from the autocmd. So if the link is passed in explicitly, we show 
    # nothing if the line is too long.
    my $short = @_;
    my $text = $CurWin->getLink(@_);
    return unless defined $text;
    my $width = $Vim::Option{'textwidth'};
    $width = $Vim::Option{'columns'} - $Vim::Option{'wrapmargin'} 
        unless $width;
    return if ( $short and length "$text" > $width - 20 );
    Vim::msg( $text );
}

# reload the given (or current) page
sub reload {
    return 0 unless my $Page = getPage(@_);
    return $Page->show($Page->format());
}

# browse to a given location. The location is taken directly from the user, 
# and supports the bookmark notation. If an extra argument is given, it 
# forces opening a new window. If the argument is empty, split horizontally, 
# if it is '!' split vertically. If no extra argument is given, split 
# (horizontally) only if there is no open browser window
sub browse {
    $uri = canonical(split ' ', shift);
    return unless defined $uri;
    return unless defined checkScheme($uri);
    if (not goBrowser() or @_) {
        # arg is '' if we want to split, '!' if we want vertical split and 
        # nothing at all if we don't insist on creating a new window
        my $Cmd = (@_ ? shift() : '');
        $Cmd =~ tr/!/v/;
        $CurWin = new VIM::Browser::Window $Cmd . 'new', ++$MaxWin;
        $Browser->{$CurWin->id} = $CurWin;
    }
    $CurWin->openNew($uri);
    unless ( $CurWin->page ) {
        # no page is associated to the window, we didn't really open anything 
        # in vim, delete the Window object
        delete $Browser->{$CurWin->id};
        undef $CurWin;
        VIM::DoCommand('quit');
    }
}

### form input methods.

# rotate input values for 'option' and 'radio' inputs. Arguments are the 
# offset (default 1) and the link (default current). For 'radio', the 
# rotation is cyclic.
sub nextInputChoice {
    my $offset = shift || 1;
    my $link = shift || $CurWin->page->findLink;
    return unless $link;
    my $input = $link->{'input'};
    my $type = $input->type;
    my $page = $CurWin->page;
    my $form = $link->{'form'};
    my $name = $input->name;
    if ( $type eq 'option' ) {
        my $value = &{$link->{'getval'}}($page);
        my @values = $input->value_names;
        my %index;
        @index{@values} = 0..$#values;
        my $index = $index{$value} + $offset;
        &{$link->{'setval'}}($page, $values[$index]) 
            unless ($index > $#values or $index < 0);
    } elsif ( $type eq 'radio' ) {
        my @values = 
            grep { $_->{'input'}->type eq 'radio' and 
                   $_->{'input'}->name eq $name } @{$form->{'vimdata'}};
        my ($value) = grep { &{$_->{'getval'}}($page) eq '*' } @values;
        my %index;
        @index{@values} = 0..$#values;
        my $index = ($index{$value} + $offset) % scalar(@values);
        &{$value->{'setval'}}($page, ' ');
        &{$values[$index]->{'setval'}}($page, '*');
    }
}

# change the value of a form input. Input is the link (default current).
sub clickInput {
    my $page = $CurWin->page;
    my $link = shift || $page->findLink;
    return unless $link;
    my $form = $link->{'form'};
    return unless $form;
    my $input = $link->{'input'};
    my $name = $input->name;
    my $type = $input->type;
    my $from = $link->{'from'};
    my $len = $link->{'to'} - $from + 1;
    my $value = &{$link->{'getval'}}($page);
    if ( $type eq 'text' ) {
        VIM::DoCommand('startinsert!');
    } elsif ( $type eq 'submit' ) {
        follow($link);
    } elsif ( $type eq 'checkbox' ) {
        &{$link->{'setval'}}($page, $value eq 'X' ? ' ' : 'X');
    } elsif ( $type eq 'radio' ) {
        foreach (@{$form->{'vimdata'}}) {
            next unless ($_->{'input'}->type eq 'radio' and 
                         $_->{'input'}->name eq $name);
            if (&{$_->{'getval'}}($page) eq '*') {
                &{$_->{'setval'}}($page, ' ');
                last;
            };
        };
        &{$link->{'setval'}}($page, '*');
    } elsif ( $type eq 'option' ) {
        my @values = $link->{'input'}->value_names;
        my @ind = (1..9, 'a'..'z')[0..$#values];
        my $choices = join("\n", map { '&' . shift(@ind) . ". $_" } @values);
        my $ind = VIM::Eval("confirm('', '$choices')" );
        return unless $ind;
        &{$link->{'setval'}}($page, $values[$ind-1]);
    } elsif ( $type eq 'password' ) {
        my $response = VIM::Eval("inputsecret('?')");
        &{$link->{'setval'}}($page, $response);
    } else { return };
}

# follow the link under the cursor
sub follow {
    my $link = shift || $CurWin->page->findLink;
    if ($link) {
        if ( my $target = $CurWin->page->linkTarget($link) ) {
            $CurWin->openNew($target) 
                if defined($target = checkScheme($target));
        } elsif ( $link->{'form'} ) {
            clickInput($link);
        }
    } else {
        Vim::error($CurWin->page . ': No link at this point!');
    }
}

# save the contents of the link under the cursor to a given file. The file is 
# either given as an argument, or is prompted from the user.
sub saveLink {
    my $link = $CurWin->getLink;
    if ($link and not ref $link) {
        return 0 unless defined($link = checkScheme($link));
        return $CurWin->openUri($link, 'save', @_);
    } else {
        Vim::error($CurWin->page . ': No link at this point!');
        return 0;
    }
}

# find the n-th next/previous link, relative to the cursor position. n is 
# given as the first parameter. It's sign determines between prev and next.
sub findNextLink {
    my ($row, $col) = $main::curwin->Cursor();
    my $count = shift;
    my $dir = $count < 0 ? -1 : 1;
    my ($link, $offset);
    while ( $dir * $count > 0 ) {
        ($link, $offset) = $CurWin->page->findNextLink($dir, $row, $col);
        if ( $link ) {
            $row += $offset;
            $col = $link->{'from'};
            $main::curwin->Cursor($row, $col);
            $count -= $dir;
        } else { last };
    }
    unless ( $link ) {
        Vim::msg('No further links');
        return;
    }
    showLinkTarget($link);
}

# show the history for the current window
sub showHist {
    return unless getPage;
    $CurWin->showHist;
}

# go back/forward in history
sub goHist {
    return unless getPage;
    $CurWin->goHist(@_);
}

sub addHeader {
    return unless my $Page = getPage;
    $Page->addHeader;
}

sub removeHeader {
    return unless my $Page = getPage;
    $Page->removeHeader;
}

# view the page source. The argument says whether to split it horizontally 
# ('') or vertically ('!')
sub viewSource {
    return unless my $Page = getPage;
    my $dir = shift;
    $dir =~ tr/!/v/;
    $Page->viewSource($dir . 'new');
}

# bookmark the current page under the given nickname. The description will 
# come from the title. If the extra argument is true, delete the given 
# bookmark.
sub bookmark {
    unless ( $AddressBookDir ) {
        Vim::error(<<'EOF');
Bookmarks are disabled. To enable bookmarks, 
set g:browser_addrbook_dir to an absolute path
EOF
        return undef;
    }
    my $name = shift;
    my $bang = shift;
    if ( $bang ) {
        delete $AddrBook{$CurrentBook}->{$name};
    } else {
        my $Page = getPage();
        $AddrBook{$CurrentBook}->{$name} = ["$Page->{'uri'}", $Page->title];
    }
}

# change to the bookmark file given by the first argument, relative to 
# $AddressBookDir. If the second argument is true, change to this file even 
# if it does not exist. This book will be the one whose bookmarks are used 
# without mentioning the book name
sub changeBookmarkFile {
    unless ( $AddressBookDir ) {
        Vim::error(<<'EOF');
Bookmarks are disabled. To enable bookmarks, 
set g:browser_addrbook_dir to an absolute path
EOF
        return undef;
    }
    my ($file, $create) = @_;
    unless ($create or -r catfile($AddressBookDir, $file)) {
        Vim::error("Bookmark file '$file' doesn't exist (use ! to create)");
        return;
    }
    $CurrentBook = $file;
    Vim::msg("Bookmark file is now '$CurrentBook'");
}
    
# list all bookmarks in the given/current bookmark file
sub listBookmarks {
    unless ( $AddressBookDir ) {
        Vim::error(<<'EOF');
Bookmarks are disabled. To enable bookmarks, 
set g:browser_addrbook_dir to an absolute path
EOF
        return undef;
    }
    my $book = $_[0] ? $_[0] : $CurrentBook;
    tied(%{$AddrBook{$book}})->list;
}

#### completion functions

# to complete bookmark file names (relative to $AddressBookDir)
sub listBookmarkFiles {
    return join("\n", map {basename $_} listDirFiles($AddressBookDir, 0));
}

# to complete (extended) uris
sub listBrowse {
    my ($Arg, $CmdLine, $Pos) = @_;
    if ( $Arg !~ /^:/o ) {
        # we have a decent uri or a file name
        my $Uri = 0;
        if ( lc($Arg) =~ /^file:/o ) {
            $Arg = (new URI $Arg)->file;
            $Uri = 1;
        } elsif ( $Arg =~ m{^(\w+):/}o and 
                  # allow drive letters on windows
	          not ( $^O eq 'MSWin32' and length($1) == 1 ) ) {
            # can't complete anything but files
            return '';
        }
        my $Dir = catpath((splitpath($Arg))[0..1]);
        my @List = listDirFiles($Dir, 1);
        # Don't use catfile here since it removes the trailing slash!
        # @List = map { catfile($Dir, $_) } @List if $Dir;
        #@List = map { "$Dir$_" } @List if $Dir;
        @List = map { (new URI::file $_)->as_string } @List if $Uri;
        return join("\n", @List);
    }
    return unless $AddressBookDir;
    if ( $Arg =~ /^:([^:]*):/o ) {
        # complete a bookmark from the given bookmarks file
        my $book = $1 ? $1 : $CurrentBook;
        return join("\n", map { ":$1:$_" } keys %{$AddrBook{$book}});
    } else {
        # complete a bookmarks file
        my $res = listBookmarkFiles();
        $res =~ s/^/:/mgo;
        $res =~ s/$/:/mgo;
        return $res;
    }
}

1;

__DATA__

# start of POD

=head1 NAME

VIM::Browser - perl part of the vim browser plugin

=head1 DESCRIPTION

This module is part of the vim(1) B<browser> plugin. It contains the 
implementation of all the functionality, except for the HTML translation, 
which is performed by L<HTML::FormatText::Vim>. It is not very useful by 
itself.

If you are looking for the documentation of the browser plugin, it's in the 
F<browser.pod> file. If you are looking for documentation about the 
implementation, look at the comments in the body of this source file.

=head1 SEE ALSO

This modules uses the following perl modules:

L<Tie::Hash>, L<Tie::Memoize>, L<Encode>, L<URI>, L<URI::Heuristic>, 
L<URI::file>, L<LWP::UserAgent>, L<HTML::Form>

From cpan, and also

L<HTML::FormatText::Vim>, L<Vim>

from the browser plugin distribution.

The documentation of the browser plugin is in F<browser.pod>

=head1 AUTHOR

Moshe Kaminsky <kaminsky@math.huji.ac.il> - Copyright (c) 2004

=head1 LICENSE

This program is free software. You may copy or 
redistribute it under the same terms as Perl itself.

=cut

