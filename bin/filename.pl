#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;
use Text::Unidecode;
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

### global vars
our ($config, $run, $current, $proc);

=TODO
1. Отдельное имя для архива (возможно с указанием на код во внешней базе)
=cut

################################################################################
#########   Creating name part
################################################################################

=name_create_full

Creates full name - private (for archive) or public: (for symlink and sharing)

# creating name for archive
=cut
sub name_create_full {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',type=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $type = $_->{type} || croak;

    # creating parts of full name
    _print_log('debug', 'name', "Creating $type folder title");
    my $name = name_create_part(
        info    => $info,
        part    => $type,
        config  => $config->{name}->{$type},
    );
    _print_log('info', 'name', "Created folder name: $name");
    return $name;
}

=name_create_part

Create part of name, accroding to given scheme

#name_create_common(info=>$info,type=>$type,part=>'full',);
=cut
sub name_create_part {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',type=>'',config=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $part = $_->{part} || croak;
    my $part_config = $_->{config} || croak;

    ### opts
    my $opts = $part_config->{opts} || croak;
    my $first_no_braces = $opts->{no_first_braces}       || 0;
    my $no_duplicate_parts = $opts->{no_duplicate_parts} || 0;
    my $braces_parts = $opts->{braces_parts}             || undef;
    my $delim_parts = $opts->{delim_parts};
    croak unless defined $delim_parts;

    ### origin (preferred lang for name)
    my $origin = $_->{origin} || info_get_origin({info=>$info});
    # unless defined $origin

    ### order
    my $order =
        $part_config->{order}->{$origin}
     || $part_config->{order}
     || croak;

    my @name_parts;
#    say Dumper $order;
    foreach ( @$order ) {
        my $opt = $_;
        my $tag;
        if ($opt =~ / %{ (.*) } /x ) {
            $tag = $1;
        }
        else {
            _print_log('error', 'config', "Wrong config entry: $part/$opt");
            croak;
        }
#        say "tag_name = $tag_name";;
        next unless defined $tag;
        my $value;
        if (defined $part_config->{part}->{$tag}) {
            $value = name_create_part(
                info    => $info,
                part    => $tag,
                config  => $part_config->{part}->{$tag});
        }
        else {
            $value = info_get_tag_value({info => $info, tag => $tag});
        }

        # required/optional/excessive value
        if ($opt =~ /^\+/) { # required part
            unless ($value) {
                _print_log('error', 'name', "Can't create required part: $part/$tag");
                return;
            }
        }
        elsif ($opt =~ /^\*/) { # important optional parts
            unless ($value) {
                _print_log('warning', 'name', "Can't create optional part: $part/$tag");
            }
        }
        elsif ($opt =~ /^\?/) { # excessive parts
            if (scalar @name_parts) {
                _print_log('info', 'name', "skipping excessive part: $part/$tag");
                next;
            }
        }
        $opt =~ s/^[+?*]//;

        ### creating final value
        next unless $value;
        name_normalize(\$value);

        # skip duplicate part of name
        if ($no_duplicate_parts) {
            my $found = 0;
            foreach (@name_parts) {
                $found ++ if name_is_included($value, $_);
            }
            next if $found;
        }

        # braces
        my $name_part;
        if (defined $braces_parts) {
            $name_part .=
                ($first_no_braces ? '' : $braces_parts->[0] )
                .$value.
                ($first_no_braces ? '' : $braces_parts->[1] );
        }
        else { # delim in the config
            if ($tag eq 'country' && $value =~ /,/) {
                # HACK
                # TODO create $name_create->{$tag_name}->()
                my @tmp = split /,/,$value;
                $name_part = "[$tmp[0]]" if scalar @tmp > 1;
            }
            else {
                $opt =~ s/%{$tag}/$value/x;
                $name_part = $opt;
            }
        }
        $first_no_braces = 0;
        unless ($name_part) {
            _print_log('warning', 'name', "Can't create part: $part/$tag");
            next;
        }
        push @name_parts, $name_part;
    }
    my $name = join($delim_parts, @name_parts);
    name_normalize(\$name);
    return unless $name;
    _print_log('info', 'name', "created $part name: $name") if $name;
    return $name;
}

sub name_is_included {
    my ($part, $string) = @_;
    name_normalize_full(\$part);
    name_normalize_full(\$string);
    return $string =~ /$part/i;
}

# return interval name belong to
sub name_get_interval {
    my $name = shift || return;
    my $first;
    my $interval;

    # enabled?
    return unless $config->{name}->{intervals}->{use};

    # first letter
    if ($name =~ /\W*(\w)/i) {
        $first = $1;
    }
    unless ($first =~ /^[0-9A-Za-zА-Яа-яЁё]$/i ) {
        $first = substr( unidecode($first), 0 , 1 );
    }
    $first = lc(substr($name, 0 , 1)) unless defined $first;

    # use first letter as interval
    return $first if $config->{name}->{intervals}->{first_letter};

    # custom intervals
    foreach (keys %{ $config->{name}->{intervals}->{custom} }) {
        return $config->{name}->{intervals}->{custom}->{$_} if $name =~ /^$_\s/i;
    }

    # default intervals
    foreach (@{ $config->{name}->{intervals}->{default} }) {
        return $_ if $first =~ /[$_]/i;
    }
    _print_log('error', 'name', "Can't determine interval for [$name]");
    return;
}

# оставить только текст/цифры, разделенный пробелами
sub name_normalize_full {
    my $str_ref = shift;

    # remove all characters except digits, letters and whitespaces
    $$str_ref =~ s/[^\w\s]/ /g;
    $$str_ref =~ s/_/ /g;

    # remove articles
    my @articles = keys %{$config->{name}->{articles}};
    foreach (@articles) {
        my $tmp = q{$_};
        $$str_ref =~ s/( $tmp |^$tmp)/ /ig;
    }

    # trim whitespaces
    name_trim($str_ref);
    return;
}

=name_normalize
Convert string to valid for filename

Input: string
Output: void
=cut
sub name_normalize {
    my $str_ref = shift;
    my $tmp = $$str_ref;

    # symbols that cannot appear in file name (and samba name)
    foreach my $s ( keys %{ $config->{name}->{restricted} } ) {
        my $tmp = quotemeta($s);
        my $replace = $config->{name}->{samba_restricted}->{$s};
        $$str_ref =~ s/$tmp/$replace/g;
    }
    name_trim($str_ref);
    return;
}

# trim whitespaces
sub name_trim {
    my $str_ref = shift;

    $$str_ref =~ s/^\s+//;      # at the beginning
    $$str_ref =~ s/\s+$//;      # at the end
    $$str_ref =~ s/\s+/ /g;     # in the middle
}

=Text normalization
http://en.wikipedia.org/wiki/Text_normalization
Examples of text normalization:
    * Unicode normalization
    * converting all letters to lower or upper case
    * removing punctuation
    * removing accent marks and other diacritics from letters
    * expanding abbreviations
    * removing stopwords or "too common" words
    * stemming

Text normalization is useful, for example, for comparing two sequences of characters which mean the same but are represented differently. The examples of this kind of normalization include, but not limited to, "don't" vs "do not", "I'm" vs "I am", "Can't" vs "Cannot".

Further, "1" and "one" are the same, "1st" is the same as "first", and so on. Instead of treating these strings as different, through text processing, one can treat them as the same.



=cut

=Stop words
http://en.wikipedia.org/wiki/Stop_words

Links:
http://armandbrahaj.blog.al/2009/04/14/list-of-english-stop-words/


http://www.textfixer.com/resources/common-english-words-with-contractions.txt
http://www.textfixer.com/resources/common-english-words.txt
http://www.textfixer.com/resources/common-english-words-3letters-plus.txt
a,able,about,across,after,all,almost,also,am,among,an,and,any,are,as,at,be,because,been,but,by,can,cannot,could,dear,did,do,does,either,else,ever,every,for,from,get,got,had,has,have,he,her,hers,him,his,how,however,i,if,in,into,is,it,its,just,least,let,like,likely,may,me,might,most,must,my,neither,no,nor,not,of,off,often,on,only,or,other,our,own,rather,said,say,says,she,should,since,so,some,than,that,the,their,them,then,there,these,they,this,tis,to,too,twas,us,wants,was,we,were,what,when,where,which,while,who,whom,why,will,with,would,yet,you,your
=cut

=contraction
http://www.textfixer.com/resources/english-contractions-list.php
http://www.textfixer.com/resources/english-contractions-list.txt

'tis,'twas,ain't,aren't,can't,could've,couldn't,didn't,doesn't,don't,hasn't,he'd,he'll,he's,how'd,how'll,how's,i'd,i'll,i'm,i've,isn't,it's,might've,mightn't,must've,mustn't,shan't,she'd,she'll,she's,should've,shouldn't,that'll,that's,there's,they'd,they'll,they're,they've,wasn't,we'd,we'll,we're,weren't,what'd,what's,when,when'd,when'll,when's,where'd,where'll,where's,who'd,who'll,who's,why'd,why'll,why's,won't,would've,wouldn't,you'd,you'll,you're,you've

=cut



1;