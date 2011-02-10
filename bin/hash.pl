#!/usr/bin/perl -w
use strict;
use warnings;
use diagnostics;
# for cloning returned data;
use Storable;
# devel
use Data::Dumper;
use Carp;
use feature ":5.10";

=TODO
hash_diff() - diff between two structures

=cut

################################################################################
#########   Complex structures part (prefix: hash)
################################################################################

sub hash_is_tag_defined {
    local %_ = @_;
    croak unless defined $_{data};
    my $data = $_{data};
    my $tag = $_{tag} || undef;

    my $ref = $data;
    if (defined $tag) {
        my @tag_parts = split /:/, $tag;
        foreach (@tag_parts) {
            unless (defined $ref->{$_}) {
                return undef;
            }
            $ref = $ref->{$_};
        }
    }
    return defined $ref ? 1 : 0;
}

# tag must be defined
sub hash_is_tag_exists {
    local %_ = @_;
    return unless defined $_{data} && defined $_{tag};
    my $data = $_{data};
    my $tag = $_{tag};

    my $ref = $data;
    my @tag_parts = split /:/, $tag;
    while (@tag_parts) {
        $tag = shift @tag_parts;
        unless (scalar @tag_parts) { # last tag
            return exists $ref->{$tag};
        }
        unless (defined $ref->{$tag}) {
            last;
        }
        $ref = $ref->{$tag};
    }
    return;
}

sub hash_is_tag_protected {
    local %_ = @_;
    croak unless defined $_{data} && defined $_{tag};
    my $protected_tag = '_protected';
    my $data = $_{data};
    my $tag = $_{tag};
    return 1 if hash_is_tag_exists(data => $data, tag => "$protected_tag:$tag");
    return 0;
}

sub hash_get_tag_ref {
    local %_ = @_;
    croak unless defined $_{data};
    my $data = $_{data};
    my $tag = $_{tag};

    my $ref = $data;
    if (defined $tag) {
        my @tag_parts = split /:/, $tag;
        while (@tag_parts) {
            $tag = shift @tag_parts;
            unless (scalar @tag_parts) { # last tag
                next;
            }
            if (defined $ref->{$tag}) {
                $ref = $ref->{$tag};
            }
            else {
                $ref = $ref->{$tag} = {};
            }
        }
    }
    return {ref => $ref, tag => $tag};
}

# return list of tags with values
#hash_hash_get_tags(data => $data->{$tag}, prefix => $prefix.$tag.":");
# TODO get_tags
sub hash_get_tags {
    local %_ = @_;
    return unless defined $_{data};
    my $data = $_{data};
    my $prefix = $_{prefix} || '';
    my @tags;
    foreach my $tag (keys %{$data}) {
        if (ref $data->{$tag}) {
            my @tmp = hash_get_tags(data => $data->{$tag}, prefix => $prefix.$tag.":");
            push @tags, @tmp;
        }
        else {
            push @tags, {tag_name => $prefix.$tag, value => $data->{$tag}};
        }
    }
    return @tags;
}

# return tag's subtag keys
sub hash_get_tag_keys { # TODO get_tags depth = 1
    local %_ = @_;
    croak unless defined $_{data};
    my $tag = $_{tag} || undef;
    my $data = $_{data};

    if ( hash_is_tag_defined(tag => $tag, data => $data) ) {
        my $ref = hash_get_tag_ref( tag => $tag, data => $data );
        my $value = $ref->{ref};
        $value = $value->{$ref->{tag}} if defined $ref->{tag};
        my @keys = keys %{$value} if defined $value;
        return @keys;
    }
    return;
}

# return tag's value
# hash_get_tag_value(tag => 'name:rus', data => $data);
# DO NOT MODIFY RETURNED VALUE !!!
sub hash_get_tag_value {
    local %_ = @_;
    croak unless defined $_{data};
    my $tag = $_{tag} || undef;
    my $data = $_{data};

    if ( hash_is_tag_defined(tag => $tag, data => $data) ) {
        my $ref = hash_get_tag_ref( tag => $tag, data => $data );
        my $value = $ref->{ref};
        $value = $value->{$ref->{tag}} if defined $ref->{tag};
#        return dclone $value;
        return $value;
    }
    return;
}

# simple assignment: tag = value
#hash_set_tag_value(tag => 'name:rus', value => $rus, data => $data);
sub hash_set_tag_value {
    local %_ = @_;
    croak unless defined $_{data};
    my $data = $_{data};
    my $tag = $_{tag};
    my $value =  $_{value};
    my $update = $_{update} || undef;
    my $no_protect = $_{no_protect} || undef;

    # do not rewrite protected tags
    if (!defined $no_protect && defined $tag && hash_is_tag_protected( data => $data, tag => $tag ) ) {
        # TODO print or log without using external sub
        _print_log('warning', "Skipping PROTECTED tag [$tag] ");
        return;
    }

    my $ref = hash_get_tag_ref( tag => $tag, data => $data );
    my $tmpref = $ref->{ref};
    if (defined $ref->{tag}) {
        # do not update with undefined value
        return if defined $update && defined $tmpref->{$ref->{tag}} && !defined $value;
        $tmpref->{$ref->{tag}} = $value;
    }
    else {
        # do not update with undefined value
        return if defined $update && defined $tmpref && !defined $value;
        $tmpref = $value;
    }
}

#hash_set_tag_value_mass(data => $data, tag => $tag, value => $value, update => $update);
# mass assignment
# ref:      data
# string :  tag: abc:def
# ref:      value: x: 1, y:2, z:z1: 3, z:z2:4, z:z3:5

# data_before_values
# data:abc:def:
#   a: 0
#   x: 2
#   y:~
#   z:
#     z1:0
#     z2:4

# data_after_values:
# data:abc:def:
#   a: 0 # not changed
#   x: 1 # updated
#   y:2  # new tag
#   z:   #
#     z1:3 # updated nested tag
#     z2:4 # not changed
#     z3:5 # new nested tag

# mass assignment and updating
sub hash_set_tag_value_mass {
    local %_ = @_;
    croak unless defined $_{data} || exists $_{value};
    my $data = $_{data};
    my $value =  $_{value};
    my $tag = $_{tag};
    my $update = $_{update};
    my $no_protect = $_{no_protect};
#    my $debug = ($value == 1);

    if (ref $value) { # multiple values
        my @tags = hash_get_tags(data => $value);
#        yaml_print(\@tags) if $debug;
        foreach (@tags) {
            my $tag_name = defined $tag ? "$tag:$_->{tag_name}" : $_->{tag_name};
            my $value = $_->{value};
            hash_set_tag_value(
                data => $data,
                tag => $tag_name,
                value => $value,
                update => $update,
                no_protect => $no_protect);
        }
    }
    else {
        hash_set_tag_value(
                data => $data,
                tag => $tag,
                value => $value,
                update => $update,
                no_protect => $no_protect);
    }
}

1;