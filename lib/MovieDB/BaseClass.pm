#/usr/bin/perl -w
package MovieDB::BaseClass;
use strict;
use warnings;
# for building "inside-out" objects
use Class::Std::Utils;
# fow www
use LWP::UserAgent;
use HTTP::Cookies;
# for cache
use Cache::FileCache;
use Storable qw{freeze thaw};
# for HTML parsing
use HTML::TreeBuilder;
# devel
use Carp;
use Data::Dumper;
use feature ':5.10';
use encoding 'utf8';
our ($VERSION, %FIELDS, $AUTOLOAD, %STATUS_DESCR);
BEGIN {
    $VERSION = '0.9';

    %STATUS_DESCR = (
        0 => 'Empty',
        1 => 'Filed',
        2 => 'Fresh',
        3 => 'Cached',
    );
}

use constant FROM_FILE        => 1;
use constant FROM_INTERNET    => 2;
use constant FROM_CACHE        => 3;

my @params_list = qw(
    proxy cookies error timeout user_agent decode_html encoding debug
    cache cache_obj cache_exp cache_root clear_cache
    parsed_cache parsed_cache_obj parsed_cache_exp parsed_cache_root parsed_clear_cache
    file
    ua host query search title_search status
    crit method code url content tree matched
    );

# %params
my %params;
foreach my $param (@params_list) {
    $params{$param} = undef;
    no strict 'refs'; # to register new methods in package
    *$param = sub {
        my $self = shift;
        $params{ident $self}->{$param} = shift if @_;
        return $params{ident $self}->{$param};
    };
}

sub new {
    my $caller = shift;
    my $class = ref($caller) || $caller;
    my $self = bless \do{my $anon_scalar}, $class;

    # Init object attributes
    $params{ident $self} = {};

    $self->_init(@_);
    return $self;
}
sub _init {
    my $self = shift;
    my (%args) = @_;

    foreach my $param (@params_list) {
        my $value = defined $args{$param}
            ? $args{$param}
            : $self->_get_default_value($param);
        $self->$param($value);
    }

    # cache
    if($self->cache) {
        my $cache = new Cache::FileCache(
            {default_expires_in => $self->cache_exp ,
            cache_root         => $self->cache_root });
        $self->cache_obj( $cache );
        $self->cache_obj->clear() if $self->clear_cache;
    }

    # parsed cache (for storing parsed HTML::TreeBuilder trees)
    if($self->parsed_cache) {
        my $cache = new Cache::FileCache(
            {default_expires_in => $self->parsed_cache_exp ,
            cache_root         => $self->parsed_cache_root });
        $self->parsed_cache_obj( $cache );
        $self->parsed_cache_obj->clear() if $self->parsed_clear_cache;
    }

    # proxy and www
    my $ua = LWP::UserAgent->new();
    if ($self->proxy) {
        $ua->proxy(['http', 'ftp'], $self->proxy);
    }
    else {
        $ua->env_proxy();
    }
    $ua->cookie_jar(HTTP::Cookies->new (file => $self->cookies, autosave => 1) ) if $self->cookies;
    $ua->timeout($self->timeout);
    $ua->agent($self->user_agent);
    $ua->show_progress( 'true' );
    $self->ua( $ua );
}

sub DESTROY {
    my ($self) = @_;
    $self->delete_tree;
    delete $params{ident $self};
    return;
}

sub load_content {
    my $self = shift;
    return $self->content unless @_;
    $self->content( undef );

    my $args = shift || croak;
    $self->get_cache_crit($args);


    my $page;
    # checking cache
    if (defined $args->{crit} && $self->cache) {
        $page = $self->cache_obj->get($args->{crit});
        if (defined $page) { # cached page
            $self->_show_message("Retrieved page from cache ...", 'DEBUG');
            $self->status(FROM_CACHE);
        }
    }

    # downloading from internet
    unless (defined $page)  {
        $self->_show_message("Retrieving page from internet ...", 'DEBUG');
        my $url = $args->{url} || $self->create_url($args);
        $page = $self->get_page_from_internet($url);
        if (defined $page) {
            $self->status(FROM_INTERNET);
            if (defined $args->{crit} && $self->cache) {
                $self->cache_obj->set($args->{crit}, $page, $self->cache_exp );
            }
        }
    }
    $self->content( \$page ) if defined $page;
    return $self->content;
}

sub load_tree {
    my $self = shift;
    return $self->tree unless @_;
    $self->delete_tree;
    $self->tree(undef);

    my $args = shift || croak;
    $self->get_cache_crit($args);


    my $tree;
    # checking cache
    if (defined $args->{crit} && $self->parsed_cache) {
        my $tree_serialised = $self->parsed_cache_obj->get( "$args->{crit}_parsed");
        if (defined $tree_serialised) { # cached
            $self->status(FROM_CACHE);
            $self->_show_message("Retrieved parsed tree from cache ...", 'DEBUG');
            $tree = thaw $tree_serialised;
        }
    }

    unless (defined $tree) {
        my $content_ref = $args->{content} || $self->load_content($args);
        return unless defined $content_ref;
        # TODO options from parameters.
        my $parser = HTML::TreeBuilder->new();
        $parser->p_strict(1);
        $tree = $parser->parse_content($$content_ref) or croak "[CRITICAL] Cannot create HTML tree: $!!";
        $tree->eof;
        if (defined $tree) {
            $self->status(FROM_INTERNET);
            if (defined $args->{crit} && $self->parsed_cache) {
                my $tree_serialised = freeze $tree;
                $self->parsed_cache_obj->set(
                    "$args->{crit}_parsed", $tree_serialised, $self->parsed_cache_exp );
            }
        }
    }

    $self->tree($tree);
    return $self->tree;
}

sub delete_tree {
    my $self = shift;
    my $tree = $self->tree;
    $tree->delete if defined $tree;
    return;
}

# getting crit for cache
sub get_cache_crit {
    my $self = shift;
    my $args = shift || croak;

    if (defined $args->{url}) {
        my $title_search = $self->title_search;
        if ($args->{url} =~ qr{$title_search} ) {
            $args->{crit} ||= $1;
        }
    }
    if (defined $args->{crit}) {
        utf8::encode($args->{crit}); # HACK
    }
    unless (defined $args->{crit}) {
        $self->_show_message("Crit not defined", 'WARNING');
        say Dumper($args);
    }
    return;
}

sub get_page_from_internet {
    my $self = shift;
    my $url = shift;
    $self->_show_message("URL is [$url]...", 'DEBUG');
    my $response = $self->ua->get ( $url );
    # TODO check for returned status >> $page->status_line;
    if ($response->is_success) {
        my $page = $response->decoded_content(charset => $self->encoding);
        return $page;
     }
     else {
        $self->_error("Cannot retieve an url: [$url]!");
        say $response->status_line;
        $self->_show_message("Cannot retrieve url [$url]", 'CRITICAL');
    }
    return;
}

sub status_descr {
    my $self = shift;
    return $STATUS_DESCR{$self->_status} || $self->status;
}


sub _error {
    my $self = shift;
    say Dumper (@_);
    if(@_) {
        push @{ $self->_error }, shift;
    }
    return join("\n", @{ $self->_error }) if $self->error;
}

sub _show_message {
    my $self = shift;
    my $msg = shift || 'Unknown error';
    my $type = shift || 'ERROR';

    return if $type =~ /^debug$/i && !$self->debug;

    if($type =~ /(debug|info|warn)/i) { carp "[$type] $msg" }
    else { croak "[$type] $msg" }
}

sub AUTOLOAD {
     my $self = shift;
    my($class, $method) = $AUTOLOAD =~ /(.*)::(.*)/;
    my($pack, $file, $line) = caller;

    carp "Method [$method] not found in the class [$class]!\n Called from $pack    at line $line";
}

1;
