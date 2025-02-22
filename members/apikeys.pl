#!/usr/bin/perl

# This file is part of Koha.
#
# Copyright 2015 BibLibre
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

use CGI;

use C4::Auth qw( get_template_and_user );
use C4::Output qw( output_and_exit output_html_with_http_headers );

use Koha::ApiKeys;
use Koha::Patrons;
use Koha::Token;

my $cgi = CGI->new;

my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {   template_name   => 'members/apikeys.tt',
        query           => $cgi,
        type            => 'intranet',
        flagsrequired   => { borrowers => 'edit_borrowers' },
    }
);

my $patron;
my $patron_id = $cgi->param('patron_id') // '';
my $api_key   = $cgi->param('key')       // '';

$patron = Koha::Patrons->find($patron_id) if $patron_id;

if ( not defined $patron or
     not C4::Context->preference('RESTOAuth2ClientCredentials') ) {

    # patron_id invalid -> exit
    print $cgi->redirect("/cgi-bin/koha/errors/404.pl"); # escape early
    exit;
}

my $op = $cgi->param('op') // '';

if ( $op eq 'generate' or
     $op eq 'delete' or
     $op eq 'revoke' or
     $op eq 'activate' ) {

    output_and_exit( $cgi, $cookie, $template, 'wrong_csrf_token' )
        unless Koha::Token->new->check_csrf({
            session_id => scalar $cgi->cookie('CGISESSID'),
            token      => scalar $cgi->param('csrf_token'),
        });
}

if ($op) {
    if ( $op eq 'generate' ) {
        my $description = $cgi->param('description') // '';
        my $api_key = Koha::ApiKey->new(
            {   patron_id   => $patron_id,
                description => $description
            }
        );
        $api_key->store;
        print $cgi->redirect( '/cgi-bin/koha/members/apikeys.pl?patron_id=' . $patron_id );
        exit;
    }

    if ( $op eq 'delete' ) {
        my $api_key_id = $cgi->param('key');
        my $key = Koha::ApiKeys->find({ patron_id => $patron_id, client_id => $api_key_id });
        if ($key) {
            $key->delete;
        }
        print $cgi->redirect( '/cgi-bin/koha/members/apikeys.pl?patron_id=' . $patron_id );
        exit;
    }

    if ( $op eq 'revoke' ) {
        my $api_key_id = $cgi->param('key');
        my $key = Koha::ApiKeys->find({ patron_id => $patron_id, client_id => $api_key_id });
        if ($key) {
            $key->active(0);
            $key->store;
        }
        print $cgi->redirect( '/cgi-bin/koha/members/apikeys.pl?patron_id=' . $patron_id );
        exit;
    }

    if ( $op eq 'activate' ) {
        my $api_key_id = $cgi->param('key');
        my $key = Koha::ApiKeys->find({ patron_id => $patron_id, client_id => $api_key_id });
        if ($key) {
            $key->active(1);
            $key->store;
        }
        print $cgi->redirect( '/cgi-bin/koha/members/apikeys.pl?patron_id=' . $patron_id );
        exit;
    }
}

my @api_keys = Koha::ApiKeys->search({ patron_id => $patron_id });

$template->param(
    api_keys   => \@api_keys,
    csrf_token => Koha::Token->new->generate_csrf({ session_id => scalar $cgi->cookie('CGISESSID') }),
    patron     => $patron
);

output_html_with_http_headers $cgi, $cookie, $template->output;
