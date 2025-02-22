#!/usr/bin/perl

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
use C4::Koha;
use C4::Biblio qw(
    GetBiblioData
    GetMarcAuthors
    GetMarcBiblio
    GetMarcSeries
    GetMarcSubjects
    GetMarcUrls
);
use C4::Items qw( GetItemsInfo );
use C4::Auth qw( get_template_and_user );
use C4::Output qw( output_html_with_http_headers );

use Koha::AuthorisedValues;
use Koha::Biblios;
use Koha::CsvProfiles;

my $query = CGI->new;

my ( $template, $borrowernumber, $cookie ) = get_template_and_user (
    {
        template_name   => "basket/basket.tt",
        query           => $query,
        type            => "intranet",
        flagsrequired   => { catalogue => 1 },
    }
);

my $bib_list     = $query->param('bib_list');
my $verbose      = $query->param('verbose');

if ($verbose)      { $template->param( verbose      => 1 ); }

my @bibs = split( /\//, $bib_list );
my @results;

my $num = 1;
my $marcflavour = C4::Context->preference('marcflavour');
if (C4::Context->preference('TagsEnabled')) {
	$template->param(TagsEnabled => 1);
	foreach (qw(TagsShowOnList TagsInputOnList)) {
		C4::Context->preference($_) and $template->param($_ => 1);
	}
}


foreach my $biblionumber ( @bibs ) {
    $template->param( biblionumber => $biblionumber );

    my $dat              = &GetBiblioData($biblionumber);
    next unless $dat;
    my $biblio           = Koha::Biblios->find( $biblionumber );
    my $record           = &GetMarcBiblio({ biblionumber => $biblionumber });
    my $marcnotesarray   = $biblio->get_marc_notes({ marcflavour => $marcflavour });
    my $marcauthorsarray = GetMarcAuthors( $record, $marcflavour );
    my $marcsubjctsarray = GetMarcSubjects( $record, $marcflavour );
    my $marcseriesarray  = GetMarcSeries  ($record,$marcflavour);
    my $marcurlsarray    = GetMarcUrls    ($record,$marcflavour);
    my @items            = GetItemsInfo( $biblionumber );

    my $hasauthors = 0;
    if($dat->{'author'} || @$marcauthorsarray) {
      $hasauthors = 1;
    }
	
    my $shelflocations =
      { map { $_->{authorised_value} => $_->{lib} } Koha::AuthorisedValues->get_descriptions_by_koha_field( { frameworkcode => $dat->{frameworkcode}, kohafield => 'items.location' } ) };

	for my $itm (@items) {
	    if ($itm->{'location'}){
	    $itm->{'location_description'} = $shelflocations->{$itm->{'location'} };
		}
	}
	# COinS format FIXME: for books Only
        my $fmt = substr $record->leader(), 6,2;
        my $fmts;
        $fmts->{'am'} = 'book';
        $dat->{ocoins_format} = $fmts->{$fmt};

    if ( $num % 2 == 1 ) {
        $dat->{'even'} = 1;
    }

    $num++;
    $dat->{biblionumber} = $biblionumber;
    $dat->{ITEM_RESULTS}   = \@items;
    $dat->{MARCNOTES}      = $marcnotesarray;
    $dat->{MARCSUBJCTS}    = $marcsubjctsarray;
    $dat->{MARCAUTHORS}    = $marcauthorsarray;
    $dat->{MARCSERIES}  = $marcseriesarray;
    $dat->{MARCURLS}    = $marcurlsarray;
    $dat->{HASAUTHORS}  = $hasauthors;

    if ( C4::Context->preference("IntranetBiblioDefaultView") eq "normal" ) {
        $dat->{dest} = "/cgi-bin/koha/catalogue/detail.pl";
    }
    elsif ( C4::Context->preference("IntranetBiblioDefaultView") eq "marc" ) {
        $dat->{dest} = "/cgi-bin/koha/catalogue/MARCdetail.pl";
    }
    else {
        $dat->{dest} = "/cgi-bin/koha/catalogue/ISBDdetail.pl";
    }
    push( @results, $dat );
}

my $resultsarray = \@results;

# my $itemsarray=\@items;

$template->param(
    BIBLIO_RESULTS => $resultsarray,
    csv_profiles => [ Koha::CsvProfiles->search({ type => 'marc', used_for => 'export_records' }) ],
    bib_list => $bib_list,
);

output_html_with_http_headers $query, $cookie, $template->output;
