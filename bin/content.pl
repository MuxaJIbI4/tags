#!/usr/bin/perl -w
use strict;
#no strict 'refs';
use warnings;
use diagnostics;

## use part
use Encode;
use File::Spec;
use File::Find::Rule;
use IO::Prompt;
use Storable qw{dclone};
use Term::ANSIColor;
use Term::ANSIColor qw(:constants);
use utf8;
use feature ":5.10";
# devel
use Carp;
use Data::Dumper;

BEGIN {
# local libs
    use FindBin qw($Bin);
    use lib "$Bin/../lib";

    # signals
    $SIG{INT} = \&_cleanup;
    # autoflush
    $|++;

    # program version
    our $VERSION = '1.1b';

    #use encoding 'utf8';
    #binmode STDOUT, ":encoding(UTF-8)";

    # loading functions for working with YAML
    require "$Bin/YAML.pl";
    # loading useful functions for working with complex hash of hashes of ... structures
    require "$Bin/hash.pl";
    # loading subs for symlink creating
    require "$Bin/symlink.pl";
    # loading subs for working with filenames
    require "$Bin/filename.pl";
    # loading subs for working with filesystem
    require "$Bin/fs.pl";
    # loading subs for working with dbs
    require "$Bin/db.pl";
    # loading subs for working with .info files
    require "$Bin/info.pl";
    # loading subs for working command-line options
    require "$Bin/options_init.pl";
}


### config
our $config;    # config

### runtime vars
our $run;
#$run->{paths}->{script_home,public,content,cache,db}
#$run->{db}->{$db}->{plugin,path}
#$run->{plugins}->{exist,enables,loaded}->{$plugin}

### parameters of currently processed content (title folder, db index, etc...)
our $current;
#$current->{db}->{index,data}->{$db}
#$current->{dir,folder,path,files, name??}
# TODO $current->{dir}->{dir,folder,path,files, name,info}
# TODO $current->{title}->{all indexes, public name}

### subs
our $proc;

=allowed
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',type=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $type = $_->{type} || croak;
=cut

################################################################################
#########   Processing folders part
################################################################################

# processing content in filesystem
sub dir_process {
    if (defined $run->{paths}->{title}) {
        dir_title();
    }
    elsif (defined $run->{paths}->{content}) {
        dir_content();
    }
}

# find and process content folders (folders with .content inside)
sub dir_content {
    my @content_dirs = dir_content_find($run->{paths}->{content});
    unless (@content_dirs ) {
        _print_log('error', 'content', "Can't find any content dirs");
        return;
    }
    @content_dirs = sort @content_dirs;
    $run->{paths}->{content} = \@content_dirs;

    while ( scalar @{$run->{paths}->{content}} ) {
        my $dir = shift @{$run->{paths}->{content}};
        next unless fs_exists($dir) && fs_directory($dir);
        fs_chdir($dir) || next;
        _print_log('qa', "Processing content folder: $dir");
        unless ( fs_writable($dir) ) {
            _print_log('warning', "$dir is not writable by effective uid/gid");
        }
        # get content folder listing
        my $content_folder_files = fs_folder_listing($dir);
        foreach ( sort keys %$content_folder_files ) {
            undef $current;
            $current->{folder} = $_;
            $current->{path} = "$dir/$current->{folder}";
            if ( $current->{folder} =~ /^!/ ) {
                _print_log('warning', "Skipping folder $dir/$current->{folder}");
                next;
            }
            next unless fs_directory($current->{path});
            _print_log('qa', "Processing folder $current->{path}");
            my $ok = dir_folder();
        }
    }
}

# recursively find content folders
sub dir_content_find {
    my $content_dir = shift;
    fs_chdir($content_dir) || return;
    _print_log('info', 'content', "processing $content_dir");
    # collection: Star Wars
    my $files = fs_folder_listing($content_dir);

    my @content_dirs;
    if ( defined $files->{'.content'} ) { # TODO config->name->content
        # found content folder
        push @content_dirs, $content_dir;
    }
    else {
        foreach my $file ( sort keys %$files ) {
            # HACK for video.campus
            if ($content_dir =~ /\/mnt$/) {
                if (
                    $file !~ /^hd(\d+)$/                # skin non hd
                 || $file =~ /^hd(03|20|21)$/           # skip incoming
                 || $file =~ /^hd(45|46|47|48)$/        # skip not video
                    ) {
                    _print_log('warning', 'content', "skipping $content_dir/$file");
                    next;
                }
            }
            next unless fs_directory("$content_dir/$file");        # skip non folder
            push @content_dirs, dir_content_find("$content_dir/$file");
        }
    }
    return @content_dirs;
}

# find and process title folders (folders with .info inside)
sub dir_title {
    my $path = $run->{paths}->{title} || return;
    fs_chdir($path) || return;
    _print_log('debug', 'title', "processing dir: $path");

    if ( fs_exists( $config->{name}->{info} ) ) {
        # found title folder
        undef $current;
        if ($path =~ /(.*)\/(.*)/) {
            my ($dir, $folder) = ($1,$2);
            $current->{folder} = $folder;
            $current->{dir} = $dir;
            $current->{path} = $path;
        }
        else {
            _print_log('error', 'fs', "Can't parse path: $path");
            croak;
        }
        _print_log('qa', 'title', "Found title folder: $current->{path}");
        my $ok = dir_folder();
    }
    else {
        my $files = fs_folder_listing($path);
        foreach my $file ( sort keys %$files ) {
            next unless fs_directory("$path/$file");
            if ($path =~ /\/mnt$/ && $file !~ /^hd(\d+)$/ || $file =~ /^hd(03|20|21|45|46|47|48)$/) {
                    _print_log('warning', 'title', "skipping $path/$file");
                    next;
            }
            dir_title("$path/$file");
        }
    }
}

################################################################################
#########   Processing folder (title/release) part
################################################################################

sub dir_folder {
    fs_chdir($current->{path}) || return;
    $current->{files} = fs_folder_listing($current->{path});
#    _print_log('info','fs', "$current->{path} is not writable") unless fs_writable($current->{path});

    # nested .content folders
    if (defined $current->{files}->{'.content'}) {
        _print_log('qa',"Found nested content folder: $current->{path}");
        unshift @{$run->{paths}->{content}}, $current->{path};
        return;
    }

    # skip info: all/recently updated
    return if dir_folder_infoskip();

    # get info
    my $info = info_get();
    return unless defined $info;

    # create symlinks/return
    return if dir_folder_symlink($info);

    # updating db/return
    return if dir_folder_update_db($info);

    # save info to file
    dir_folder_infosave($info);

    # update all .info in subfolders
    dir_folder_infoupdate($info);

    # Folder renaming. optional
    dir_folder_rename({info=>$info});

    # moving files into release folder/subfolder
    dir_folder_move($info);

    # looking in database for title's alternative paths
    dir_folder_dupes({info=>$info});

    # TODO show-stat [+] [-] [?] [+/-]
#    my $line = prompt("\nPress to continue? > ");
#    sleep 1;
    return 1;
}

################################################################################
#########   Processing options
################################################################################

sub dir_folder_move {
    return unless defined $run->{options}->{move};
    return unless defined $current->{files}->{ $config->{name}->{info} };

    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;

    # rename folder using alternative .info. HACK for releases
    my @files = File::Find::Rule
        ->file
        ->name( $config->{name}->{info} )
        ->mindepth(2)
        ->relative
        ->in(fs_encode($current->{path}));
    foreach (@files) {
        my $file = fs_decode($_);
        my $tmpinfo = info_load($file);
        next unless defined $tmpinfo;
        if ($file =~ / (.+) \/ ([^\/]+) \/ ([^\/]+) /x) {
            my $path = $1;
            say "path = $path";
            dir_folder_move_info({
                info    => $tmpinfo,
                path    => $path});
        }
    }

    # rename folder using main .info
    # order is important: first move subfolders, and in the end - main folder
    dir_folder_move_info({info=>$info});

}

=dir_folder_move
Move/rename private archive folder according to .info
=cut
sub dir_folder_move_info {
    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'',path=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    my $path = $_->{path};

    # Skip season releases
    if (info_get_tag_value(info=>$info,tag=>'content') eq 'series'
     || info_get_tag_value(info=>$info,tag=>'kind') eq 'series') {
        return unless $path;
    }

    # creating new name
    my $new = name_create_full({info=>$info,type=>'release_full'});
    unless ($new) {
        _print_log('error', 'move', "Can't create new folder title");
        return;
    }

    # move files
    if ( fs_exists("$current->{dir}/$new") ) { # destination folder already exists
        if ($new ne $current->{folder}) {
            _print_log('warning', 'move', "Can't move: Destination exists: $new");
        }
        else {
            _print_log('info', 'move', "Can't move: Folder's name is already good");
        }
        return;
    }
    else {
        say $path if $path;
        my $old = $current->{folder}.(defined $path ? "/$path" : '');
        _print_log('qa', 'move', "Moving subfolder");
        my $line = prompt(
            "\tOrig: ", $old,
            "\n\tNew : ", $new,
            "\nDo you want to move folder? yes/no [default:no] > ");

        if ($line =~ /^(y|yes)$/) {
            #fs_chdir $current->{dir} || return;
            my $ok;
#            eval {
                _print_log('warning', 'move', "moving $old ---> $new");
#                $ok = fs_move($old, $new); # TODO eval
#            }
#            if($@) {
#                _print_log('warning', $@);
#            }
            if ($ok) {
                _print_log('qa', 'move', "Successfully moved $old ---> $new");
                unless ($path) {
                    $current->{folder} = $new;
                    $current->{path} = "$current->{dir}/$current->{folder}";
                    fs_chdir $current->{path} || croak;
                }
            }
            else {
                _print_log('warning', 'move', "Couldn't moved $old ---> $new");
            }
        }
    }
    return;
}


=about
Searches duplicates of titles in given folder and prints paths to them
Input: .info
=cut
sub dir_folder_dupes {
    return unless defined $run->{options}->{dupes};
    return unless defined $current->{files}->{ $config->{name}->{info} };

    local $_ = shift || croak;
    # check for allowed keys
    my %allowed_keys = (info=>'');
    foreach my $key (keys %{$_}) {croak unless exists $allowed_keys{$key};}
    # check for correct values (defined/not)
    my $info = $_->{info} || croak;
    _print_log('qa', 'dupes', "Searching for duplicates");

    my @titles = info_titles({info => $info});
    my $found = 0;
    foreach my $title (@titles) {
        $found += title_dupes({title=>$title,path=>$current->{path}});
    }
    my $line = prompt("\nFound $found duplicates. Press to continue? > ") if $found;
}

sub dir_folder_infosave {
    return unless defined $run->{options}->{'infosave'};

    my $info = shift || croak;
    _print_log('qa', 'infosave', "Saving info");
    info_normalize($info); # TODO move to get info

    # prompt
    yaml_print($info);
    my $line = prompt(
        "\nDo you want to save this info to disk? yes/no [default:no]"), ;
    if ($line =~ /y|yes/i) {
        # saving to disk
        # .info
        info_save("$current->{path}/$config->{name}->{info}", $info) || return;
        $current->{files}->{ $config->{name}->{info} } = 1
            if fs_exists("$current->{path}/$config->{name}->{info}");
        info_update(info => $info, dir => $current->{path}, mindepth => 2 );
    }
}

sub dir_folder_infoupdate {
    return unless $run->{options}->{'infoupdate'};
    return unless defined $current->{files}->{ $config->{name}->{info} };
    my $info = shift || croak;
    info_update(info => $info, dir => $current->{path}, mindepth => 1 );
}

#info_update(data => $data, dir => $current->{path}, mindepth => 2 );
sub info_update {
    local %_ = @_;
    my %allowed_keys = (dir=>'',info=>'',mindepth=>'');
    foreach (keys %_) {croak unless exists $allowed_keys{$_};}
    croak unless defined $_{info} && defined $_{dir};
    my $info = $_{info};
    my $dir = $_{dir};
    my $mindepth = $_{mindepth} || 1;
    _print_log('qa', 'infoupdate', "Updating sub infos");

    my $tmpinfo = dclone $info;
    my $path = $current->{path};
    my @files = File::Find::Rule
        ->file
        ->name( $config->{name}->{info} )
        ->mindepth($mindepth)
        ->in(fs_encode($path));
    foreach (@files) {
        my $file = $_;
        $file = fs_decode($file);
        my $tmpdata = info_load($file);
        next unless defined $tmpdata;
        $tmpinfo->{release} = $tmpdata->{release};
        my $ok = info_save($file, $tmpinfo);
        if ($ok) {
            _print_log('info', 'infoupdate', "Successfully updated: ", $file);
        }
        else {
            _print_log('warning', 'infoupdate', "Can't update: ", $file);
        }
    }
}

sub dir_folder_infoskip {
    my $ret = 0;
    return $ret unless defined $run->{options}->{infoskip};
    return $ret unless defined $current->{files}->{ $config->{name}->{info} };

    $ret = 1 if $run->{options}->{'infoskip'} == 0;
    $ret = 1 if $run->{options}->{'infoskip'} && fs_modified( $config->{name}->{info} ) < $run->{options}->{'infoskip'};
    _print_log('warning', 'infoskip', "skipping $current->{path}") if $ret;
    return $ret;
};

sub dir_folder_symlink {
    return unless defined $run->{options}->{symlink};
    my $info = shift || croak;
    symlink_create($info);
    return 1;
}

# TODO title_save_db;
# saving updated data to db
# save to db (scan/rescan). save db data, save path (for dupes, ...)
# TODO db_add_title_path(info => $info, path => $current->{path});
sub dir_folder_update_db {
    return if defined $run->{options}->{no_use_db};
    return unless $run->{options}->{'db'} eq 'scan';
    return unless defined $current->{files}->{ $config->{name}->{info} };
    my $info = shift || croak;

    # TODO info_update_db????????
    my @titles = info_titles({info=>$info});
    foreach my $title (@titles) {
        next if $title eq '0'; # default title
        title_update_db({info=>$info,title=>$title});
    }
    return 1; # continue with next folder
}


################################################################################
#########   Service subroutines
################################################################################

# load found plugins
sub plugins_load_all {
    unless (defined $run->{plugin}->{path}) {
        plugins_find();
        return unless defined $run->{plugin}->{path};
    }
    foreach my $plugin (keys %{$run->{plugin}->{enabled}} ) {
        plugins_load($plugin);
    }
    my $t1 = scalar keys %{$run->{plugin}->{enabled}};
    my $t2 = scalar keys %{$run->{plugin}->{loaded}};
    _print_log('qa', 'plugins', "Loaded plugins: $t2/$t1");
    foreach (keys %{$run->{plugin}->{loaded}}) {
        _print_log('qa', 'plugins', "\t$_\t$run->{plugin}->{path}->{$_}");
    }
}

# find existing plugins
sub plugins_find {
    foreach my $plugin (keys %{$config->{plugins}}) {
        next unless fs_exists("$run->{paths}->{script_home}/plugins/$plugin.pl");
        $run->{plugin}->{path}->{$plugin} = "$run->{paths}->{script_home}/plugins/$plugin.pl";
        $run->{plugin}->{enabled}->{$plugin} = 1 if $config->{plugins}->{$plugin}->{enabled};
        _print_log('info', "Found plugin: $plugin in plugins/$plugin.pl");
    }
}

# load given plugin
sub plugins_load {
    my $plugin = shift || croak;
    unless (defined $run->{plugin}->{path}->{$plugin}) {
        plugins_find();
        return unless defined $run->{plugin}->{exist}->{$plugin};
    }
    eval {
        my $path = fs_encode($run->{plugin}->{path}->{$plugin});
        require $path;
    };
    if ($@) {
        _print_log('error', 'plugin',  "Error while loading plugin $plugin: $@");
    }
    else {
        $run->{plugin}->{loaded}->{$plugin} = 1;
        _print_log('info', 'plugin', "Loaded plugin $plugin");
    }
}

sub _clean_public_folders() {
    # find -L . -type l -name '*' -exec rm -rf {} \;
    # find . -type -d -empty -exec rmdir {} \;
    # remove all broken symlinks
#    _print_log('info', "Removing broken symlinks", );
    #`find -L $paths{'games_public'} -type l -name '*' -exec rm -rf {} \;`;
    # remove all empty directories
#    _print_log('info', "Removing empty folders");
    #`find -L $paths{'games_public'} -type d -empty -exec rmdir {} \;`;
}

sub _cleanup {
    my $signame = shift;
    carp "Caught signal $signame";
    exit;
}


sub _print_log {
    my (@str) = @_;
    my %log = (
        error   => 0,
        warning => 1,
        qa      => 2,
        info    => 3,
        debug   => 4,
    );
    if ($str[0] !~ /^(error|warning|qa|info|debug)$/i) {
        printf( "%-7s: %-s: %s\n", 'error', (caller(1))[3], "wrong _print_log() parameter: $str[0]. Exiting..." );
        croak;
    }
    return if $log{ $str[0] } > $run->{options}->{verbose};

    print color 'bold red'      if $str[0] eq 'error';
    print color 'bold yellow'   if $str[0] eq 'warning';
    print color 'bold blue'     if $str[0] eq 'qa';
    print color 'green'         if $str[0] eq 'info';
    my $level = shift @str;
    printf "%s: ", $level;
    print color 'reset' if $level eq 'info';
    my $caller = '';
    $caller = (caller(1))[3].':' if ($level =~ /error|warning/i ) && (caller(1))[3];
    printf "%s: ",$caller if $caller ne  '';
    printf "%s\n", join(": ",@str);
    print color 'reset';
    #print($log_handle,$str."\n");
}

################################################################################
#########   main() subroutines
################################################################################

sub _init {
    $run->{time_begin} = time;
    $run->{paths}->{start} = fs_getcwd();
    if ($Bin =~ /\/bin$/i) {
        $run->{paths}->{script_home} = fs_abs_path("$Bin/..");
    }
    else {
        $run->{paths}->{script_home} = fs_abs_path("$Bin");
    }
    $run->{options}->{verbose} = 2;

    init_options();

    # load plugins
    plugins_load_all();

    # loading db
    db_process('init');


    _print_log('qa', "Started script with options:");
    my $tmp = {};
    $tmp->{options} = $run->{options};
    $tmp->{paths} = $run->{paths};
    say BOLD, BLUE, yaml_dump($tmp), RESET;
    _print_log('qa', 'time', "Loaded in ". (time - $run->{time_begin}). " seconds");
}

sub _finalize {
    my $t0 = time;
    # saving db
    db_dump_all();

    # service
    $run->{time_end} = time;
    _print_log('qa', 'time', "Finalized in ". ($run->{time_end} - $t0). " seconds");
    _print_log('qa', 'time', "Processed in ". ($run->{time_end} - $run->{time_begin}). " seconds");
}

main();
sub main {
    #clean_public_folders();

    # init
    _init();

    if (defined $run->{options}->{test}) {
        _print_log('qa', "TESTING");
    }
    else {
        if ($run->{options}->{process} eq 'db') {
            db_process();
        }
        if ($run->{options}->{process} eq 'dir') {
            dir_process();
        }
    }
    # finalizing
    _finalize();

    #enable logging
    #unlink($log_file);
    #open($log_handle,">".$log_file) or die "Can't open log file for writing\n";
    #close($log_handle);
    # cleaning empty folders and  broken symlinks
    #clean_public_folders();
}

__END__

=head1 NAME

B<tag.pl> - managing your content collection

=head1 SYNOPSIS

B<tags.pl> [options]

options:

    --help, -h
    --man
    --verbose, -v loglevel
    --content,-c path
    --public path
    --preset, -p preset
    --dupes, -d
    --infosave
    --infoskip, -i number
    --infocheck
    --move, -m
    --rename, -r
    --symlink, -s
    --test
    --ext
    --db command

=head1 EXAMPLE

=over

=item tags.pl -c path -p parse -i 1

=item tags.pl -c path --rename --move --infosave --ext -i 1

=item tags.pl -c path -ermi1 --infosave

parse content folder B<path> and skip .info files modifies less than 1 day ago

=item tags.pl -c path -p check

=item tags.pl -c path --preset check

=item tags.pl -c path --preset=check

=item tags.pl -c path --rename --move --dupes --infocheck

=item tags.pl -c path -rmd --infocheck

do check on B<path>

=item tags.pl --preset symlink

=item tags.pl --symlink

create symlinks

=back

=head1 DESCRIPTION

With B<tags.pl> you can:

=over

=item 1.
Determine given title and get some information about it from internet

=item 2.
validate content metadata

=item 3.
Create symlinks for given content using highly configurable scheme

=back


=head1 OPTIONS

!!!!!HELP IS OUTDATED!!!!!!

=over

=item B<--help>

Print brief help message and exits.

=item B<--man>

Prints manual page and exits.

=item B<--verbose, -v loglevel>

Define verbosity of log output. Loglevel can take following values:

 errror, 0   - errors,
 warning, 1  - warnings,
 qa,2        - warnings + QA (default level),
 info, 3     - some info when processing,
 debug, 4    - detailed output

=item B<--content, -c path>

Define root of directory with content.

=item B<--public path>

Define public folder for symlinks

=item B<--preset, -p preset>

Use predefined set of options. You can freely add any option even with existing preset.

Current sets are:

=over

=item B<parse>:
options: rename,move,infosave,ext

=item B<check>:
options: rename,move,infocheck,dupes

=item B<symlink>:
options: symlink

=back

=item B<--dupes, -d>

Waiting for user input on found duplicates

=item B<--infosave>

Save .info files

=item B<--infoskip, -i number>

Skip .info files if the were modified less than B<number> days ago or always if B<number>=0

=item B<--infocheck>

Waiting for user input on invaild .info file

=item B<--move, -m>

Moving content in title folder into release folder

=item B<--rename, -r>

Rename title folder

=item B<--symlink, -s>

Create symlinks

=item B<--test>

Execute script but do not actually process content dirs

=item B<--ext, -e>

Allow search in external databases

=item B<--db>

Execute command on db. Allowed commands are: B<clear>, B<rescan>, B<scan>

=over

=item B<clear>

delete B<all> paths information from db

=item B<scan>

scan given content folders and add title and releases to db

=item B<rescan>

execute clear, then scan

=back

!!!!!HELP IS OUTDATED!!!!!!

=back

=head1 PLUGINS

B<tags.pl> can use external plugins for getting information about title

Current plugins for video are: B<imdb>, B<kp>

=head2 B<imdb>

use imdb.com search
TODO: give some info about using it

=head2 B<kp>

use kinopoisk.ru search
TODO: give some info about using it

=head1 VERSION HISTORY

0.2
    - $dir, $folder now global
    - db: imdb <=> kp codes
    - some cleaning of the code

0.3
    - subroutines for .info processing
    - [feature] when creating symlink tags - use also .info in subfolders
    - defining content-dir from command-line
    - [bug][fixed] hdtv missing >> all release tags missing

0.4
    - full help
    - colored output
    - add QA output level
    - QA checking of info file
    - added checking .info files for required tags (year, lang, etc)
    - release names can be created from .info in subfolders. (season 5.ru,en)

0.5
    - tag 'Collection'
    - nested content folders, needed for for collections
    - better processing folder listing - read all files at once
    - debug info: -d loglevel
      removed options -q,-v-d . loglevel = 0(e),1(w),2(q),3(i),4(d). default: 2
    - move content into release folder

0.6
    - presets
    - clean dumping of $info - show russian letters
    - using articles to create symlinks: the, a, an, der, die, das
    - adding undefined symlink and required tags - to ease manual filling
    - normalize $info before saving
    - [db] database rework. db.titles: key->paths,plugins(imdb_key,kp_key), db.imdb: imdb_key>key.,,,,
    - [db] saving part of path that is only mnt
    - moved plugin subroutines to appropriate files

0.7 beta
    - loading plugins
    - some work on help
    - 'ext' option to allow info searching in external db
    - some nice formatting
    - added --man option
    - added --db options

0.8
    - [FIXED] when first character in public name is not ascii or russian cyryllic interval not defined
    - added kinopoisk top 250
    - added imdb top 250
    - [config] added fs: samba_restricted option for restricted characters and their replacements
    - complete rewrite of symlink functions: added symlink_root, aliases
    - now --content can use relative paths: /path_to_script/tags.pl -c .
    - added content: documentary and moved series/movie to tag:kind
    - added tag title/origin with allowed values: russsian, soviet, eng (foreign)
    - added tag1:tag2 - nested tags support
    - [plugin] save values returned by plugin to db and to .info
    - [plugin] print values returned by kp,imdb - optional
    - new internal option: 'process' = {dir, db}. dir: processing content folders, db: processing db

0.9 beta
    - infosave now updates title: part of all .info in subfolders.
    - extended configuration of title/interval
    - [db] options  --db update --dbname xxx
    - [db] options  --db check --dbname xxx
    - [db] options  --db clearpath
    - added default symlink options for title with undefined content
    - [BUG] fixed memory leak: HTML::Element should be deleted directly
    - options and db now not global
    - created db.pl for db subroutines
    - created YAML.pl for working with yaml files;
    - new option --cache cache_root
    - title index begins from 1. 0 for unknown or undefined index

1.0
    - .info just a splice of db data
    - data driven behaviour
    - [FIXED] now creating right info from unsorted folders' names
    - [FIXED] now working creating symlinks form unsorted folders

1.1
    - one can choose encoding of filesystem (filenames actually), and output

1.2 beta
    - TODO support for not one-for-one db indexes (codes).
    - TODO create subs for working with info structure (it should be transparent for all subs
      using info from .info and db)


1.5
    - TODO one can chooes order od data - --infoorder db,disk (disk,db)
    - TODO get_code working only with data, get_index - only with info
    - custom config for each plugin
    - config.content.yml for different types of content
    - default config options rewrited by custom config
    - multiple tag's symlink names: series/сериалы, etc...
    - TODO genre rus <=> genre eng
    - rus name not only changes order of names but language of optional tags
    - support for not one-to-one indexes (one imdb index >> includes 3 kp indexes)

2.0 future features ??? TODO ???
    - TODO info_normalize in get_final_info() and not in infosave only
    - TODO change tag value in given conten folder tag_.pl -c . --tag origin --set(--delete) 'russian'
    - TODO add option --show-stat
    - TODO symink content/kind/tags
    - TODO FAQ ???
    - TODO skip folders that need to be writable for processing but they are not
    - TODO config_* subroutines: config_load, config_validate
    - TODO check for write possibility for appropriate functions: move, rename, saveinfo
    - TODO db locking when processing
    - TODO caching of HTML::Treebuilder's trees
    - [plugin] TODO check plugins kp, imdb for right processing of html data

    - [plugin] Full writers 0063127 (and 1 more writer) >> fullcredits
    - [plugin] imdb: {cast, year,...},kp: {cast, year,...}, ....
    - cleaning of broken symlinks and empty folders
    - TODO renaming releases according to .info and moving
    - TODO avdump?
    - TODO new files , new from 2010
    - try to search with other names if first didn't succeed

    - [feature] skip lang/ru
    - all/fiction/documentary/animation/TV/Reality TV : series/movies
    - unidecode eng name with utf8 characters ???

=cut
