#!/usr/bin/perl

# This file is part of Koha.
#
# Script to manage the opac news.
# written 11/04
# Casta�eda, Carlos Sebastian - seba3c@yahoo.com.ar - Physics Library UNLP Argentina
# Modified to include news to KOHA intranet - tgarip@neu.edu.tr NEU library -Cyprus
# Copyright 2000-2002 Katipo Communications
# Copyright (C) 2013    Mark Tompsett
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
use C4::Auth qw( get_template_and_user );
use C4::Context;
use C4::Output qw( output_html_with_http_headers );
use C4::Languages qw( getTranslatedLanguages );
use Koha::DateUtils qw( dt_from_string output_pref );
use Koha::News;

my $cgi = CGI->new;

my $id             = $cgi->param('id');
my $title          = $cgi->param('title');
my $content        = $cgi->param('content');
my $expirationdate;
if ( $cgi->param('expirationdate') ) {
    $expirationdate = output_pref({ dt => dt_from_string( scalar $cgi->param('expirationdate') ), dateformat => 'iso', dateonly => 1 });
}
my $published_on= output_pref({ dt => dt_from_string( scalar $cgi->param('published_on') ), dateformat => 'iso', dateonly => 1 });
my $number         = $cgi->param('number');
my $lang           = $cgi->param('lang');
my $branchcode     = $cgi->param('branch');
my $error_message  = $cgi->param('error_message');
my $wysiwyg;
if( $cgi->param('editmode') ){
    $wysiwyg = $cgi->param('editmode') eq "wysiwyg" ? 1 : 0;
} else {
    $wysiwyg = C4::Context->preference("NewsToolEditor") eq "tinymce" ? 1 : 0;
}

# Foreign Key constraints work with NULL, not ''
# NULL = All branches.
$branchcode = undef if (defined($branchcode) && $branchcode eq '');

my $new_detail = Koha::News->find( $id );

my ( $template, $borrowernumber, $cookie ) = get_template_and_user(
    {
        template_name   => "tools/koha-news.tt",
        query           => $cgi,
        type            => "intranet",
        flagsrequired   => { tools => 'edit_news' },
    }
);

# Pass error message if there is one.
$template->param( error_message => $error_message ) if $error_message;

# get lang list
my @lang_list;
my $tlangs = getTranslatedLanguages() ;

foreach my $language ( @$tlangs ) {
    foreach my $sublanguage ( @{$language->{'sublanguages_loop'}} ) {
        push @lang_list,
        {
            language => $sublanguage->{'rfc4646_subtag'},
            selected => ( $new_detail && $new_detail->lang eq $sublanguage->{'rfc4646_subtag'} ? 1 : 0 ),
        };
    }
}

$template->param( lang_list   => \@lang_list,
                  branchcode  => $branchcode );

my $op = $cgi->param('op') // '';

if ( $op eq 'add_form' ) {
    $template->param( add_form => 1 );
    if ($id) {
        if($new_detail->lang eq "slip"){ $template->param( slip => 1); }
        $template->param( 
            op => 'edit',
            id => $new_detail->idnew
        );
        $template->{VARS}->{'new_detail'} = $new_detail;
    }
    else {
        $template->param( op => 'add' );
    }
}
elsif ( $op eq 'add' ) {
    if ($title) {
        my $new = Koha::NewsItem->new({
            title          => $title,
            content        => $content,
            lang           => $lang,
            expirationdate => $expirationdate,
            published_on   => $published_on,
            number         => $number,
            branchcode     => $branchcode,
            borrowernumber => $borrowernumber,
        })->store;
        print $cgi->redirect("/cgi-bin/koha/tools/koha-news.pl");
    }
    else {
        print $cgi->redirect("/cgi-bin/koha/tools/koha-news.pl?error_message=title_missing");
    }
}
elsif ( $op eq 'edit' ) {
    my $news_item = Koha::News->find( $id );
    if ( $news_item ) {
        $news_item->set({
            title          => $title,
            content        => $content,
            lang           => $lang,
            expirationdate => $expirationdate,
            published_on=> $published_on,
            number         => $number,
            branchcode     => $branchcode,
        })->store;
    }
    print $cgi->redirect("/cgi-bin/koha/tools/koha-news.pl");
}
elsif ( $op eq 'del' ) {
    my @ids = $cgi->multi_param('ids');
    Koha::News->search({ idnew => \@ids })->delete;
    print $cgi->redirect("/cgi-bin/koha/tools/koha-news.pl");
}

else {
    my $params;
    $params->{lang} = $lang if $lang;
    my $opac_news = Koha::News->search(
        $params,
        {
            order_by => { -desc =>  'published_on' },
        }
    );
    $template->param( opac_news => $opac_news );
}
$template->param(
    lang => $lang,
    wysiwyg => $wysiwyg,
);
output_html_with_http_headers $cgi, $cookie, $template->output;
