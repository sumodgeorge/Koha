#!/usr/bin/perl

# Copyright 2010-2011 MASmedios.com y Ministerio de Cultura
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
use CGI qw ( -utf8 );
use CGI::Cookie;
use C4::Context;
use C4::Auth qw( check_cookie_auth );
use C4::ImportExportFramework qw( createODS ExportFramework ImportFramework );

my %cookies = CGI::Cookie->fetch();
my $authenticated = 0;
my ($auth_status, $sessionID);
if (exists $cookies{'CGISESSID'}) {
    ($auth_status, $sessionID) = check_cookie_auth(
        $cookies{'CGISESSID'}->value,
        { parameters => 'manage_marc_frameworks' },
    );
}
if ($auth_status eq 'ok') {
    $authenticated = 1;
}

my $input = CGI->new;

unless ($authenticated) {
    print $input->header(-type => 'text/plain', -status => '403 Forbidden');
    exit 0;
}

my $framework_name = $input->param('frameworkcode') || 'default';
my $frameworkcode = ($framework_name eq 'default') ? q{} : $framework_name;
my $action = $input->param('action') || 'export';

## Exporting
if ($action eq 'export' && $input->request_method() eq 'GET') {
    my $strXml = '';
    my $format = $input->param('type_export_' . $framework_name);
    ExportFramework($frameworkcode, \$strXml, $format);

    if ($format eq 'csv') {
        # CSV file

        # Correctly set the encoding to output plain text in UTF-8
        binmode(STDOUT,':encoding(UTF-8)');
        print $input->header(-type => 'application/vnd.ms-excel', -attachment => 'export_' . $framework_name . '.csv');
        print $strXml;
    } else {
        # ODS file
        my $strODS = '';
        createODS($strXml, 'en', \$strODS);
        print $input->header(-type => 'application/vnd.oasis.opendocument.spreadsheet', -attachment => 'export_' . $framework_name . '.ods');
        print $strODS;
    }
## Importing
} elsif ($input->request_method() eq 'POST') {
    my $ok = -1;
    my $fieldname = 'file_import_' . $framework_name;
    my $filename = $input->param($fieldname);
    # upload the input file
    if ($filename && $filename =~ /\.(csv|ods)$/i) {
        my $extension = $1;
        my $uploadFd = $input->upload($fieldname);
        if ($uploadFd && !$input->cgi_error) {
            my $tmpfilename = $input->tmpFileName(scalar $input->param($fieldname));
            $filename = $tmpfilename . '.' . $extension; # rename the tmp file with the extension
            $ok = ImportFramework($filename, $frameworkcode, 1) if (rename($tmpfilename, $filename));
        }
    }
    if ($ok >= 0) { # If everything went ok go to the framework marc structure
        print $input->redirect( -location => '/cgi-bin/koha/admin/marctagstructure.pl?frameworkcode=' . $frameworkcode);
    } else {
        # If something failed go to the list of frameworks and show message
        print $input->redirect( -location => '/cgi-bin/koha/admin/biblio_framework.pl?error_import_export=' . $frameworkcode);
    }
}
