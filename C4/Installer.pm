package C4::Installer;

# Copyright (C) 2008 LibLime
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Encode;
use DBIx::RunSQL;
use YAML::XS;
use C4::Context;
use DBI;
use Koha;

use vars qw(@ISA @EXPORT);
BEGIN {
    require Exporter;
    @ISA = qw( Exporter );
    push @EXPORT, qw( primary_key_exists unique_key_exists foreign_key_exists index_exists column_exists TableExists marc_framework_sql_list);
};

=head1 NAME

C4::Installer

=head1 SYNOPSIS

 use C4::Installer;
 my $installer = C4::Installer->new();
 my $all_languages = getAllLanguages();
 my $error = $installer->load_db_schema();
 my $list;
 #fill $list with list of sql files
 my ($fwk_language, $error_list) = $installer->load_sql_in_order($all_languages, @$list);
 $installer->set_version_syspref();
 $installer->set_marcflavour_syspref('MARC21');

=head1 DESCRIPTION

=cut

=head1 METHODS

=head2 new

  my $installer = C4::Installer->new();

Creates a new installer.

=cut

sub new {
    my $class = shift;

    my $self = {};

    # get basic information from context
    $self->{'dbname'}   = C4::Context->config("database");
    $self->{'dbms'}     = C4::Context->config("db_scheme") ? C4::Context->config("db_scheme") : "mysql";
    $self->{'hostname'} = C4::Context->config("hostname");
    $self->{'port'}     = C4::Context->config("port");
    $self->{'user'}     = C4::Context->config("user");
    $self->{'password'} = C4::Context->config("pass");
    $self->{'tls'} = C4::Context->config("tls");
    if( $self->{'tls'} && $self->{'tls'} eq 'yes' ) {
        $self->{'ca'} = C4::Context->config('ca');
        $self->{'cert'} = C4::Context->config('cert');
        $self->{'key'} = C4::Context->config('key');
        $self->{'tlsoptions'} = ";mysql_ssl=1;mysql_ssl_client_key=".$self->{key}.";mysql_ssl_client_cert=".$self->{cert}.";mysql_ssl_ca_file=".$self->{ca};
        $self->{'tlscmdline'} =  " --ssl-cert ". $self->{cert} . " --ssl-key " . $self->{key} . " --ssl-ca ".$self->{ca}." "
    }
    $self->{'dbh'} = DBI->connect("DBI:$self->{dbms}:dbname=$self->{dbname};host=$self->{hostname}" .
                                  ( $self->{port} ? ";port=$self->{port}" : "" ).
                                  ( $self->{tlsoptions} ? $self->{tlsoptions} : ""),
                                  $self->{'user'}, $self->{'password'});
    $self->{'language'} = undef;
    $self->{'marcflavour'} = undef;
	$self->{'dbh'}->do('set NAMES "utf8"');
    $self->{'dbh'}->{'mysql_enable_utf8'}=1;

    bless $self, $class;
    return $self;
}

=head2 marc_framework_sql_list

  my ($defaulted_to_en, $list) = 
     $installer->marc_framework_sql_list($lang, $marcflavour);

Returns in C<$list> a structure listing the filename, description, section,
and mandatory/optional status of MARC framework scripts available for C<$lang>
and C<$marcflavour>.

If the C<$defaulted_to_en> return value is true, no scripts are available
for language C<$lang> and the 'en' ones are returned.

=cut

sub marc_framework_sql_list {
    my $self = shift;
    my $lang = shift;
    my $marcflavour = shift;

    my $defaulted_to_en = 0;

    undef $/;
    my $dir = C4::Context->config('intranetdir') . "/installer/data/$self->{dbms}/$lang/marcflavour/".lc($marcflavour);
    unless (opendir( MYDIR, $dir )) {
        if ($lang eq 'en') {
            warn "cannot open MARC frameworks directory $dir";
        } else {
            # if no translated MARC framework is available,
            # default to English
            $dir = C4::Context->config('intranetdir') . "/installer/data/$self->{dbms}/en/marcflavour/".lc($marcflavour);
            opendir(MYDIR, $dir) or warn "cannot open English MARC frameworks directory $dir";
            $defaulted_to_en = 1;
        }
    }
    my @listdir = sort grep { !/^\.|marcflavour/ && -d "$dir/$_" } readdir(MYDIR);
    closedir MYDIR;

    my @fwklist;
    my $request = $self->{'dbh'}->prepare("SELECT value FROM systempreferences WHERE variable='FrameworksLoaded'");
    $request->execute;
    my ($frameworksloaded) = $request->fetchrow;
    $frameworksloaded = '' unless defined $frameworksloaded; # avoid warning
    my %frameworksloaded;
    foreach ( split( /\|/, $frameworksloaded ) ) {
        $frameworksloaded{$_} = 1;
    }

    foreach my $requirelevel (@listdir) {
        opendir( MYDIR, "$dir/$requirelevel" );
        my @listname = grep { !/^\./ && -f "$dir/$requirelevel/$_" && $_ =~ m/\.(sql|yml)$/ } readdir(MYDIR);
        closedir MYDIR;
        my %cell;
        my @frameworklist;
        map {
            my ( $name, $ext ) = split /\./, $_;
            my @lines;
            if ( $ext =~ /yml/ ) {
                my $yaml = YAML::XS::LoadFile("$dir/$requirelevel/$name\.$ext");
                @lines = @{ $yaml->{'description'} };
            } else {
                open my $fh, "<:encoding(UTF-8)", "$dir/$requirelevel/$name.txt";
                my $line = <$fh>;
                $line = Encode::encode('UTF-8', $line) unless ( Encode::is_utf8($line) );
                @lines = split /\n/, $line;
            }
            my $mandatory = ($requirelevel =~ /(mandatory|requi|oblig|necess)/i);
            push @frameworklist,
              {
                'fwkname'        => $name,
                'fwkfile'        => "$dir/$requirelevel/$_",
                'fwkdescription' => \@lines,
                'checked'        => ( ( $frameworksloaded{$_} || $mandatory ) ? 1 : 0 ),
                'mandatory'      => $mandatory,
              };
        } @listname;
        my @fwks =
          sort { $a->{'fwkname'} cmp $b->{'fwkname'} } @frameworklist;

        $cell{"frameworks"} = \@fwks;
        $cell{"label"}      = ($requirelevel =~ /(mandatory|requi|oblig|necess)/i)?'mandatory':'optional';
        $cell{"code"}       = lc($requirelevel);
        push @fwklist, \%cell;
    }

    return ($defaulted_to_en, \@fwklist);
}

=head2 sample_data_sql_list

  my ($defaulted_to_en, $list) = $installer->sample_data_sql_list($lang);

Returns in C<$list> a structure listing the filename, description, section,
and mandatory/optional status of sample data scripts available for C<$lang>.
If the C<$defaulted_to_en> return value is true, no scripts are available
for language C<$lang> and the 'en' ones are returned.

=cut

sub sample_data_sql_list {
    my $self = shift;
    my $lang = shift;

    my $defaulted_to_en = 0;

    undef $/;
    my $dir = C4::Context->config('intranetdir') . "/installer/data/$self->{dbms}/$lang";
    unless (opendir( MYDIR, $dir )) {
        if ($lang eq 'en') {
            warn "cannot open sample data directory $dir";
        } else {
            # if no sample data is available,
            # default to English
            $dir = C4::Context->config('intranetdir') . "/installer/data/$self->{dbms}/en";
            opendir(MYDIR, $dir) or warn "cannot open English sample data directory $dir";
            $defaulted_to_en = 1;
        }
    }
    my @listdir = sort grep { !/^\.|marcflavour/ && -d "$dir/$_" } readdir(MYDIR);
    closedir MYDIR;

    my @levellist;
    my $request = $self->{'dbh'}->prepare("SELECT value FROM systempreferences WHERE variable='FrameworksLoaded'");
    $request->execute;
    my ($frameworksloaded) = $request->fetchrow;
    $frameworksloaded = '' unless defined $frameworksloaded; # avoid warning
    my %frameworksloaded;
    foreach ( split( /\|/, $frameworksloaded ) ) {
        $frameworksloaded{$_} = 1;
    }

    foreach my $requirelevel (@listdir) {
        opendir( MYDIR, "$dir/$requirelevel" );
        my @listname = grep { !/^\./ && -f "$dir/$requirelevel/$_" && $_ =~ m/\.(sql|yml)$/ } readdir(MYDIR);
        closedir MYDIR;
        my %cell;
        my @frameworklist;
        map {
            my ( $name, $ext ) = split /\./, $_;
            my @lines;
            if ( $ext =~ /yml/ ) {
                my $yaml = YAML::XS::LoadFile("$dir/$requirelevel/$name\.$ext");
                @lines = @{ $yaml->{'description'} };
            } else {
                open my $fh, "<:encoding(UTF-8)", "$dir/$requirelevel/$name.txt";
                my $line = <$fh>;
                $line = Encode::encode('UTF-8', $line) unless ( Encode::is_utf8($line) );
                @lines = split /\n/, $line;
            }
            my $mandatory = ($requirelevel =~ /(mandatory|requi|oblig|necess)/i);
            push @frameworklist,
              {
                'fwkname'        => $name,
                'fwkfile'        => "$dir/$requirelevel/$_",
                'fwkdescription' => \@lines,
                'checked'        => ( ( $frameworksloaded{$_} || $mandatory ) ? 1 : 0 ),
                'mandatory'      => $mandatory,
              };
        } @listname;
        my @fwks = sort { $a->{'fwkname'} cmp $b->{'fwkname'} } @frameworklist;

        $cell{"frameworks"} = \@fwks;
        $cell{"label"}      = ($requirelevel =~ /(mandatory|requi|oblig|necess)/i)?'mandatory':'optional';
        $cell{"code"}       = lc($requirelevel);
        push @levellist, \%cell;
    }

    return ($defaulted_to_en, \@levellist);
}

=head2 load_db_schema

  my $error = $installer->load_db_schema();

Loads the SQL script that creates Koha's tables and indexes.  The
return value is a string containing error messages reported by the
load.

=cut

sub load_db_schema {
    my $self = shift;

    my $datadir = C4::Context->config('intranetdir') . "/installer/data/$self->{dbms}";

    # Disable checks before load
    $self->{'dbh'}->do(q{SET NAMES utf8mb4});
    $self->{'dbh'}->do(q{SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0});
    $self->{'dbh'}->do(q{SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0});
    $self->{'dbh'}->do(q{SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO'});
    $self->{'dbh'}->do(q{SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0});

    # Load kohastructure
    my $error = $self->load_sql("$datadir/kohastructure.sql");

    # Re-enable checks after load
    $self->{'dbh'}->do(q{SET SQL_MODE=@OLD_SQL_MODE});
    $self->{'dbh'}->do(q{SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS});
    $self->{'dbh'}->do(q{SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS});
    $self->{'dbh'}->do(q{SET SQL_NOTES=@OLD_SQL_NOTES});

    return $error;

}

=head2 load_sql_in_order

  my ($fwk_language, $list) = $installer->load_sql_in_order($all_languages, @sql_list);

Given a list of SQL scripts supplied in C<@sql_list>, loads each of them
into the database and sets the FrameworksLoaded system preference to names
of the scripts that were loaded.

The SQL files are loaded in alphabetical order by filename (not including
directory path).  This means that dependencies among the scripts are to
be resolved by carefully naming them, keeping in mind that the directory name
does *not* currently count.

B<FIXME:> this is a rather delicate way of dealing with dependencies between
the install scripts.

The return value C<$list> is an arrayref containing a hashref for each
"level" or directory containing SQL scripts; the hashref in turns contains
a list of hashrefs containing a list of each script load and any error
messages associated with the loading of each script.

B<FIXME:> The C<$fwk_language> code probably doesn't belong and needs to be
moved to a different method.

=cut

sub load_sql_in_order {
    my $self = shift;
    my $langchoice = shift;
    my $all_languages = shift;
    my @sql_list = @_;

    my $lang;
    my %hashlevel;
    my @fnames = sort {
        my @aa = split /\/|\\/, ($a);
        my @bb = split /\/|\\/, ($b);
        $aa[-1] cmp $bb[-1]
    } @sql_list;
    my $request = $self->{'dbh'}->prepare( "SELECT value FROM systempreferences WHERE variable='FrameworksLoaded'" );
    $request->execute;
    my ($systempreference) = $request->fetchrow;
    $systempreference = '' unless defined $systempreference; # avoid warning

    my $global_mandatory_dir = C4::Context->config('intranetdir') . "/installer/data/$self->{dbms}/mandatory";

    # Make sure some stuffs are loaded first
    unshift(@fnames,
        "$global_mandatory_dir/sysprefs.sql",
        "$global_mandatory_dir/subtag_registry.sql",
        "$global_mandatory_dir/auth_val_cat.sql",
        "$global_mandatory_dir/message_transport_types.sql",
        "$global_mandatory_dir/sample_notices_message_attributes.sql",
        "$global_mandatory_dir/sample_notices_message_transports.sql",
        "$global_mandatory_dir/keyboard_shortcuts.sql",
    );

    push @fnames, "$global_mandatory_dir/userflags.sql",
                  "$global_mandatory_dir/userpermissions.sql",
                  "$global_mandatory_dir/audio_alerts.sql",
                  "$global_mandatory_dir/account_offset_types.sql",
                  "$global_mandatory_dir/account_credit_types.sql",
                  "$global_mandatory_dir/account_debit_types.sql",
                  ;
    my $localization_file = C4::Context->config('intranetdir') .
                            "/installer/data/$self->{dbms}/localization/$langchoice/custom.sql";
    if ( $langchoice ne 'en' and -f $localization_file ) {
        push @fnames, $localization_file;
    }
    foreach my $file (@fnames) {
        #      warn $file;
        undef $/;
        my $error = $self->load_sql($file);
        my @file = split qr(\/|\\), $file;
        $lang = $file[ scalar(@file) - 3 ] unless ($lang);
        my $level = ( $file =~ /(localization)/ ) ? $1 : $file[ scalar(@file) - 2 ];
        unless ($error) {
            $systempreference .= "$file[scalar(@file)-1]|"
              unless ( index( $systempreference, $file[ scalar(@file) - 1 ] ) >= 0 );
        }

        #Bulding here a hierarchy to display files by level.
        push @{ $hashlevel{$level} },
          { "fwkname" => $file[ scalar(@file) - 1 ], "error" => $error };
    }

    #systempreference contains an ending |
    chop $systempreference;
    my @list;
    map { push @list, { "level" => $_, "fwklist" => $hashlevel{$_} } } keys %hashlevel;
    my $fwk_language;
    for my $each_language (@$all_languages) {

        #       warn "CODE".$each_language->{'language_code'};
        #       warn "LANG:".$lang;
        if ( $lang eq $each_language->{'language_code'} ) {
            $fwk_language = $each_language->{language_locale_name};
        }
    }
    my $updateflag =
      $self->{'dbh'}->do(
        "UPDATE systempreferences set value=\"$systempreference\" where variable='FrameworksLoaded'"
      );

    unless ( $updateflag == 1 ) {
        my $string =
            "INSERT INTO systempreferences (value, variable, explanation, type) VALUES (\"$systempreference\",'FrameworksLoaded','Frameworks loaded through webinstaller','choice')";
        my $rq = $self->{'dbh'}->prepare($string);
        $rq->execute;
    }
    return ($fwk_language, \@list);
}

=head2 set_marcflavour_syspref

  $installer->set_marcflavour_syspref($marcflavour);

Set the 'marcflavour' system preference.  The incoming
C<$marcflavour> references to a subdirectory of
installer/data/$dbms/$lang/marcflavour, and is
normalized to MARC21, UNIMARC or NORMARC.

FIXME: this method assumes that the MARC flavour will be either
MARC21, UNIMARC or NORMARC.

=cut

sub set_marcflavour_syspref {
    my $self = shift;
    my $marcflavour = shift;

    # we can have some variants of marc flavour, by having different directories, like : unimarc_small and unimarc_full, for small and complete unimarc frameworks.
    # marc_cleaned finds the marcflavour, without the variant.
    my $marc_cleaned = 'MARC21';
    $marc_cleaned = 'UNIMARC' if $marcflavour =~ /unimarc/i;
    $marc_cleaned = 'NORMARC' if $marcflavour =~ /normarc/i;
    my $request =
        $self->{'dbh'}->prepare(
          "INSERT IGNORE INTO `systempreferences` (variable,value,explanation,options,type) VALUES('marcflavour','$marc_cleaned','Define global MARC flavor (MARC21, UNIMARC or NORMARC) used for character encoding','MARC21|UNIMARC|NORMARC','Choice');"
        );
    $request->execute;
}

=head2 set_version_syspref

  $installer->set_version_syspref();

Set or update the 'Version' system preference to the current
Koha software version.

=cut

sub set_version_syspref {
    my $self = shift;

    my $kohaversion = Koha::version();
    # remove the 3 last . to have a Perl number
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;
    if (C4::Context->preference('Version')) {
        warn "UPDATE Version";
        my $finish=$self->{'dbh'}->prepare("UPDATE systempreferences SET value=? WHERE variable='Version'");
        $finish->execute($kohaversion);
    } else {
        warn "INSERT Version";
        my $finish=$self->{'dbh'}->prepare("INSERT into systempreferences (variable,value,explanation) values ('Version',?,'The Koha database version. WARNING: Do not change this value manually, it is maintained by the webinstaller')");
        $finish->execute($kohaversion);
    }
    C4::Context->clear_syspref_cache();
}

=head2 set_languages_syspref

  $installer->set_languages_syspref();

Add the installation language to 'language' and 'OPACLanguages' system preferences
if different from 'en'

=cut

sub set_languages_syspref {
    my $self     = shift;
    my $language = shift;

    return if ( not $language or $language eq 'en' );

    warn "UPDATE Languages";
    # intranet
    my $pref = $self->{'dbh'}->prepare("UPDATE systempreferences SET value=? WHERE variable='language'");
    $pref->execute("en,$language");
    # opac
    $pref = $self->{'dbh'}->prepare("UPDATE systempreferences SET value=? WHERE variable='OPACLanguages'");
    $pref->execute("en,$language");

    C4::Context->clear_syspref_cache();
}

=head2 process_yml_table

  my $query_info   = $installer->process_yml_table($table);

Analyzes a table loaded in YAML format.
Returns the values required to build an insert statement.

=cut

sub process_yml_table {
    my ($table) = @_;
    my $table_name   = ( keys %$table )[0];                          # table name
    my @rows         = @{ $table->{$table_name}->{rows} };           #
    my @columns      = ( sort keys %{$rows[0]} );                    # column names
    my $fields       = join ",", map{sprintf("`%s`", $_)} @columns;  # idem, joined
    my $query        = "INSERT INTO $table_name ( $fields ) VALUES ";
    my @multiline    = @{ $table->{$table_name}->{'multiline'} };    # to check multiline values;
    my $placeholders = '(' . join ( ",", map { "?" } @columns ) . ')'; # '(?,..,?)' string
    my @values;
    foreach my $row ( @rows ) {
        push @values, [ map {
                        my $col = $_;
                        ( @multiline and grep { $_ eq $col } @multiline )
                        ? join "\r\n", @{$row->{$col}}                # join multiline values
                        : $row->{$col};
                     } @columns ];
    }
    return { query => $query, placeholders => $placeholders, values => \@values };
}

=head2 load_sql

  my $error = $installer->load_sql($filename);

Runs the specified input file using a sql loader DBIx::RunSQL, or a yaml loader
Returns any strings sent to STDERR

# FIXME This should be improved: sometimes the caller and load_sql warn the same
error.

=cut

sub load_sql {
    my $self = shift;
    my $filename = shift;
    my $error;

    my $dbh = $self->{ dbh };

    my $dup_stderr;
    do {
        local *STDERR;
        open STDERR, ">>", \$dup_stderr;

        if ( $filename =~ /sql$/ ) {                                                        # SQL files
            eval {
                DBIx::RunSQL->run_sql_file(
                    dbh     => $dbh,
                    sql     => $filename,
                );
            };
        }
        else {                                                                       # YAML files
            eval {
                my $yaml         = YAML::XS::LoadFile( $filename );                            # Load YAML
                for my $table ( @{ $yaml->{'tables'} } ) {
                    my $query_info   = process_yml_table($table);
                    my $query        = $query_info->{query};
                    my $placeholders = $query_info->{placeholders};
                    my $values       = $query_info->{values};
                    # Doing only 1 INSERT query for the whole table
                    my @all_rows_values = map { @$_ } @$values;
                    $query .= join ', ', ( $placeholders ) x scalar @$values;
                    $dbh->do( $query, undef, @all_rows_values );
                }
                for my $statement ( @{ $yaml->{'sql_statements'} } ) {               # extra SQL statements
                    $dbh->do($statement);
                }
            };
        }
        if ($@){
            warn "Something went wrong loading file $filename ($@)";
        }
    };
    #   errors thrown while loading installer data should be logged
    if( $dup_stderr ) {
        warn "C4::Installer::load_sql returned the following errors while attempting to load $filename:\n";
        $error = $dup_stderr;
    }

    return $error;
}

=head2 get_file_path_from_name

  my $filename = $installer->get_file_path_from_name('script_name');

searches through the set of known SQL scripts and finds the fully
qualified path name for the script that mathches the input.

returns undef if no match was found.


=cut

sub get_file_path_from_name {
    my $self = shift;
    my $partialname = shift;

    my $lang = 'en'; # FIXME: how do I know what language I want?

    my ($defaulted_to_en, $list) = $self->sample_data_sql_list($lang);
    # warn( Data::Dumper->Dump( [ $list ], [ 'list' ] ) );

    my @found;
    foreach my $frameworklist ( @$list ) {
        push @found, grep { $_->{'fwkfile'} =~ /$partialname$/ } @{$frameworklist->{'frameworks'}};
    }

    # warn( Data::Dumper->Dump( [ \@found ], [ 'found' ] ) );
    if ( 0 == scalar @found ) {
        return;
    } elsif ( 1 < scalar @found ) {
        warn "multiple results found for $partialname";
        return;
    } else {
        return $found[0]->{'fwkfile'};
    }

}

sub primary_key_exists {
    my ( $table_name, $key_name ) = @_;
    my $dbh = C4::Context->dbh;
    my ($exists) = $dbh->selectrow_array(
        qq|
        SHOW INDEX FROM $table_name
        WHERE key_name = 'PRIMARY' AND column_name = ?
        |, undef, $key_name
    );
    return $exists;
}

sub foreign_key_exists {
    my ( $table_name, $constraint_name ) = @_;
    my $dbh = C4::Context->dbh;
    my (undef, $infos) = $dbh->selectrow_array(qq|SHOW CREATE TABLE $table_name|);
    return $infos =~ m|CONSTRAINT `$constraint_name` FOREIGN KEY|;
}

sub unique_key_exists {
    my ( $table_name, $constraint_name ) = @_;
    my $dbh = C4::Context->dbh;
    my (undef, $infos) = $dbh->selectrow_array(qq|SHOW CREATE TABLE $table_name|);
    return $infos =~ m|UNIQUE KEY `$constraint_name`|;
}

sub index_exists {
    my ( $table_name, $key_name ) = @_;
    my $dbh = C4::Context->dbh;
    my ($exists) = $dbh->selectrow_array(
        qq|
        SHOW INDEX FROM $table_name
        WHERE key_name = ?
        |, undef, $key_name
    );
    return $exists;
}

sub column_exists {
    my ( $table_name, $column_name ) = @_;
    return unless TableExists($table_name);
    my $dbh = C4::Context->dbh;
    my ($exists) = $dbh->selectrow_array(
        qq|
        SHOW COLUMNS FROM $table_name
        WHERE Field = ?
        |, undef, $column_name
    );
    return $exists;
}

sub TableExists { # Could be renamed table_exists for consistency
    my $table = shift;
    eval {
                my $dbh = C4::Context->dbh;
                local $dbh->{PrintError} = 0;
                local $dbh->{RaiseError} = 1;
                $dbh->do(qq{SELECT * FROM $table WHERE 1 = 0 });
            };
    return 1 unless $@;
    return 0;
}


=head1 AUTHOR

C4::Installer is a refactoring of logic originally from installer/installer.pl, which was
originally written by Henri-Damien Laurant.

Koha Development Team <http://koha-community.org/>

Galen Charlton <galen.charlton@liblime.com>

=cut

1;
