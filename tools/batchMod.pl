#!/usr/bin/perl


# Copyright 2000-2002 Katipo Communications
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

use CGI qw ( -utf8 );
use Modern::Perl;
use Try::Tiny qw( catch try );

use C4::Auth qw( get_template_and_user haspermission );
use C4::Output qw( output_html_with_http_headers );
use C4::Biblio qw(
    DelBiblio
    GetAuthorisedValueDesc
    GetMarcFromKohaField
    GetMarcStructure
    IsMarcStructureInternal
    TransformHtmlToXml
);
use C4::Items qw( GetItemsInfo Item2Marc ModItemFromMarc );
use C4::Circulation qw( LostItem IsItemIssued );
use C4::Context;
use C4::Koha;
use C4::BackgroundJob;
use C4::ClassSource qw( GetClassSources GetClassSource );
use MARC::File::XML;
use List::MoreUtils qw( uniq );

use Koha::Database;
use Koha::Exceptions::Exception;
use Koha::AuthorisedValues;
use Koha::Biblios;
use Koha::DateUtils qw( dt_from_string );
use Koha::Items;
use Koha::ItemTypes;
use Koha::Patrons;
use Koha::SearchEngine::Indexer;

my $input = CGI->new;
my $dbh = C4::Context->dbh;
my $error        = $input->param('error');
my @itemnumbers  = $input->multi_param('itemnumber');
my $biblionumber = $input->param('biblionumber');
my $op           = $input->param('op');
my $del          = $input->param('del');
my $del_records  = $input->param('del_records');
my $src          = $input->param('src');
my $use_default_values = $input->param('use_default_values');
my $exclude_from_local_holds_priority = $input->param('exclude_from_local_holds_priority');

my $template_name;
my $template_flag;
if (!defined $op) {
    $template_name = "tools/batchMod.tt";
    $template_flag = { tools => '*' };
    $op = q{};
} else {
    $template_name = ($del) ? "tools/batchMod-del.tt" : "tools/batchMod-edit.tt";
    $template_flag = ($del) ? { tools => 'items_batchdel' }   : { tools => 'items_batchmod' };
}

my ($template, $loggedinuser, $cookie)
    = get_template_and_user({template_name => $template_name,
                 query => $input,
                 type => "intranet",
                 flagsrequired => $template_flag,
                 });

$template->param( searchid => scalar $input->param('searchid'), );

# Does the user have a restricted item edition permission?
my $uid = $loggedinuser ? Koha::Patrons->find( $loggedinuser )->userid : undef;
my $restrictededition = $uid ? haspermission($uid,  {'tools' => 'items_batchmod_restricted'}) : undef;
# In case user is a superlibrarian, edition is not restricted
$restrictededition = 0 if ($restrictededition != 0 && C4::Context->IsSuperLibrarian());

$template->param(del       => $del);

my $nextop="";
my @errors; # store errors found while checking data BEFORE saving item.
my $items_display_hashref;
our $tagslib = &GetMarcStructure(1);

my $deleted_items = 0;     # Number of deleted items
my $deleted_records = 0;   # Number of deleted records ( with no items attached )
my $not_deleted_items = 0; # Number of items that could not be deleted
my @not_deleted;           # List of the itemnumbers that could not be deleted
my $modified_items = 0;    # Numbers of modified items
my $modified_fields = 0;   # Numbers of modified fields

my %cookies = parse CGI::Cookie($cookie);
my $sessionID = $cookies{'CGISESSID'}->value;


#--- ----------------------------------------------------------------------------
if ($op eq "action") {
#-------------------------------------------------------------------------------
    my @tags      = $input->multi_param('tag');
    my @subfields = $input->multi_param('subfield');
    my @values    = $input->multi_param('field_value');
    my @searches  = $input->multi_param('regex_search');
    my @replaces  = $input->multi_param('regex_replace');
    my @modifiers = $input->multi_param('regex_modifiers');
    my @disabled  = $input->multi_param('disable_input');
    # build indicator hash.
    my @ind_tag   = $input->multi_param('ind_tag');
    my @indicator = $input->multi_param('indicator');

    # Is there something to modify ?
    # TODO : We shall use this var to warn the user in case no modification was done to the items
    my $values_to_modify = scalar(grep {!/^$/} @values) || scalar(grep {!/^$/} @searches);
    my $values_to_blank  = scalar(@disabled);

    my $marcitem;

    #initializing values for updates
    my (  $itemtagfield,   $itemtagsubfield) = &GetMarcFromKohaField( "items.itemnumber" );
    if ($values_to_modify){
        my $xml = TransformHtmlToXml(\@tags,\@subfields,\@values,\@indicator,\@ind_tag, 'ITEM');
        $marcitem = MARC::Record::new_from_xml($xml, 'UTF-8');
    }
    if ($values_to_blank){
        foreach my $disabledsubf (@disabled){
            if ($marcitem && $marcitem->field($itemtagfield)){
                $marcitem->field($itemtagfield)->update( $disabledsubf => "" );
            }
            else {
                $marcitem = MARC::Record->new();
                $marcitem->append_fields( MARC::Field->new( $itemtagfield, '', '', $disabledsubf => "" ) );
            }
        }
    }

    my $upd_biblionumbers;
    my $del_biblionumbers;
    try {
        my $schema = Koha::Database->new->schema;
        $schema->txn_do(
            sub {
                # For each item
                my $i = 1;
                foreach my $itemnumber (@itemnumbers) {
                    my $item = Koha::Items->find($itemnumber);
                    next
                      unless $item
                      ; # Should have been tested earlier, but just in case...
                    my $itemdata = $item->unblessed;
                    if ($del) {
                        my $return = $item->safe_delete;
                        if ( ref( $return ) ) {
                            $deleted_items++;
                            push @$upd_biblionumbers, $itemdata->{'biblionumber'};
                        }
                        else {
                            $not_deleted_items++;
                            push @not_deleted,
                              {
                                biblionumber => $itemdata->{'biblionumber'},
                                itemnumber   => $itemdata->{'itemnumber'},
                                barcode      => $itemdata->{'barcode'},
                                title        => $itemdata->{'title'},
                                reason       => $return,
                              };
                        }

                        # If there are no items left, delete the biblio
                        if ($del_records) {
                            my $itemscount = Koha::Biblios->find( $itemdata->{'biblionumber'} )->items->count;
                            if ( $itemscount == 0 ) {
                                my $error = DelBiblio( $itemdata->{'biblionumber'}, { skip_record_index => 1 } );
                                unless ($error) {
                                    $deleted_records++;
                                    push @$del_biblionumbers, $itemdata->{'biblionumber'};
                                    if ( $src eq 'CATALOGUING' ) {
                                        # We are coming catalogue/detail.pl, there were items from a single bib record
                                        $template->param( biblio_deleted => 1 );
                                    }
                                }
                            }
                        }
                    }
                    else {
                        my $modified_holds_priority = 0;
                        if ( defined $exclude_from_local_holds_priority && $exclude_from_local_holds_priority ne "" ) {
                            if(!defined $item->exclude_from_local_holds_priority || $item->exclude_from_local_holds_priority != $exclude_from_local_holds_priority) {
                            $item->exclude_from_local_holds_priority($exclude_from_local_holds_priority)->store;
                            $modified_holds_priority = 1;
                        }
                        }
                        my $modified = 0;
                        if ( $values_to_modify || $values_to_blank ) {
                            my $localmarcitem = Item2Marc($itemdata);

                            for ( my $i = 0 ; $i < @tags ; $i++ ) {
                                my $search = $searches[$i];
                                next unless $search;

                                my $tag = $tags[$i];
                                my $subfield = $subfields[$i];
                                my $replace = $replaces[$i];

                                my $value = $localmarcitem->field( $tag )->subfield( $subfield );
                                my $old_value = $value;

                                my @available_modifiers = qw( i g );
                                my $retained_modifiers = q||;
                                for my $modifier ( split //, $modifiers[$i] ) {
                                    $retained_modifiers .= $modifier
                                        if grep {/$modifier/} @available_modifiers;
                                }
                                if ( $retained_modifiers =~ m/^(ig|gi)$/ ) {
                                    $value =~ s/$search/$replace/ig;
                                }
                                elsif ( $retained_modifiers eq 'i' ) {
                                    $value =~ s/$search/$replace/i;
                                }
                                elsif ( $retained_modifiers eq 'g' ) {
                                    $value =~ s/$search/$replace/g;
                                }
                                else {
                                    $value =~ s/$search/$replace/;
                                }

                                my @fields_to = $localmarcitem->field($tag);
                                foreach my $field_to_update ( @fields_to ) {
                                    unless ( $old_value eq $value ) {
                                        $modified++;
                                        $field_to_update->update( $subfield => $value );
                                    }
                                }
                            }

                            $modified += UpdateMarcWith( $marcitem, $localmarcitem );
                            if ($modified) {
                                eval {
                                    if (
                                        my $item = ModItemFromMarc(
                                            $localmarcitem,
                                            $itemdata->{biblionumber},
                                            $itemnumber,
                                            { skip_record_index => 1 },
                                        )
                                      )
                                    {
                                        LostItem(
                                            $itemnumber,
                                            'batchmod',
                                            undef,
                                            { skip_record_index => 1 }
                                        ) if $item->{itemlost}
                                          and not $itemdata->{itemlost};
                                    }
                                };
                                push @$upd_biblionumbers, $itemdata->{'biblionumber'};
                            }
                        }
                        $modified_items++ if $modified || $modified_holds_priority;
                        $modified_fields += $modified + $modified_holds_priority;
                    }
                    $i++;
                }
                if (@not_deleted) {
                    Koha::Exceptions::Exception->throw(
                        'Some items have not been deleted, rolling back');
                }
            }
        );
    }
    catch {
        if ( $_->isa('Koha::Exceptions::Exception') ) {
            $template->param( deletion_failed => 1 );
        }
        die "Something terrible has happened!"
            if ($_ =~ /Rollback failed/); # Rollback failed
    };
    $upd_biblionumbers = [ uniq @$upd_biblionumbers ]; # Only update each bib once

    # Don't send specialUpdate for records we are going to delete
    my %del_bib_hash = map{ $_ => undef } @$del_biblionumbers;
    @$upd_biblionumbers = grep( ! exists( $del_bib_hash{$_} ), @$upd_biblionumbers );

    my $indexer = Koha::SearchEngine::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX });
    $indexer->index_records( $upd_biblionumbers, 'specialUpdate', "biblioserver", undef ) if @$upd_biblionumbers;
    $indexer->index_records( $del_biblionumbers, 'recordDelete', "biblioserver", undef ) if @$del_biblionumbers;

    # Once the job is done
    # If we have a reasonable amount of items, we display them
    my $max_items = $del ? C4::Context->preference("MaxItemsToDisplayForBatchDel") : C4::Context->preference("MaxItemsToDisplayForBatchMod");
    if (scalar(@itemnumbers) <= $max_items ){
        if (scalar(@itemnumbers) <= 1000 ) {
            $items_display_hashref=BuildItemsData(@itemnumbers);
        } else {
            # Else, we only display the barcode
            my @simple_items_display = map {
                my $itemnumber = $_;
                my $item = Koha::Items->find($itemnumber);
                {
                    itemnumber   => $itemnumber,
                    barcode      => $item ? ( $item->barcode // q{} ) : q{},
                    biblionumber => $item ? $item->biblio->biblionumber : q{},
                };
            } @itemnumbers;
            $template->param("simple_items_display" => \@simple_items_display);
        }
    } else {
        $template->param( "too_many_items_display" => scalar(@itemnumbers) );
        $template->param( "job_completed" => 1 );
    }

    # Calling the template
    $template->param(
        modified_items => $modified_items,
        modified_fields => $modified_fields,
    );

}
#
#-------------------------------------------------------------------------------
# build screen with existing items. and "new" one
#-------------------------------------------------------------------------------

if ($op eq "show"){
    my $filefh = $input->upload('uploadfile');
    my $filecontent = $input->param('filecontent');
    my ( @notfoundbarcodes, @notfounditemnumbers);

    my $split_chars = C4::Context->preference('BarcodeSeparators');
    if ($filefh){
        binmode $filefh, ':encoding(UTF-8)';
        my @contentlist;
        while (my $content=<$filefh>){
            $content =~ s/[\r\n]*$//;
            push @contentlist, $content if $content;
        }

        if ($filecontent eq 'barcode_file') {
            @contentlist = grep /\S/, ( map { split /[$split_chars]/ } @contentlist );
            @contentlist = uniq @contentlist;
            # Note: adding lc for case insensitivity
            my %itemdata = map { lc($_->{barcode}) => $_->{itemnumber} } @{ Koha::Items->search({ barcode => \@contentlist }, { columns => [ 'itemnumber', 'barcode' ] } )->unblessed };
            @itemnumbers = map { exists $itemdata{lc $_} ? $itemdata{lc $_} : () } @contentlist;
            @notfoundbarcodes = grep { !exists $itemdata{lc $_} } @contentlist;
        }
        elsif ( $filecontent eq 'itemid_file') {
            @contentlist = uniq @contentlist;
            my %itemdata = map { $_->{itemnumber} => 1 } @{ Koha::Items->search({ itemnumber => \@contentlist }, { columns => [ 'itemnumber' ] } )->unblessed };
            @itemnumbers = grep { exists $itemdata{$_} } @contentlist;
            @notfounditemnumbers = grep { !exists $itemdata{$_} } @contentlist;
        }
    } else {
        if (defined $biblionumber && !@itemnumbers){
            my @all_items = GetItemsInfo( $biblionumber );
            foreach my $itm (@all_items) {
                push @itemnumbers, $itm->{itemnumber};
            }
        }
        if ( my $list = $input->param('barcodelist') ) {
            my @barcodelist = grep /\S/, ( split /[$split_chars]/, $list );
            @barcodelist = uniq @barcodelist;
            # Note: adding lc for case insensitivity
            my %itemdata = map { lc($_->{barcode}) => $_->{itemnumber} } @{ Koha::Items->search({ barcode => \@barcodelist }, { columns => [ 'itemnumber', 'barcode' ] } )->unblessed };
            @itemnumbers = map { exists $itemdata{lc $_} ? $itemdata{lc $_} : () } @barcodelist;
            @notfoundbarcodes = grep { !exists $itemdata{lc $_} } @barcodelist;
        }
    }

    # Flag to tell the template there are valid results, hidden or not
    if(scalar(@itemnumbers) > 0){ $template->param("itemresults" => 1); }
    # Only display the items if there are no more than pref MaxItemsToProcessForBatchMod or MaxItemsToDisplayForBatchDel
    my $max_display_items = $del
        ? C4::Context->preference("MaxItemsToDisplayForBatchDel")
        : C4::Context->preference("MaxItemsToDisplayForBatchMod");
    $template->param("too_many_items_process" => scalar(@itemnumbers)) if !$del && scalar(@itemnumbers) > C4::Context->preference("MaxItemsToProcessForBatchMod");
    if (scalar(@itemnumbers) <= ( $max_display_items // 1000 ) ) {
        $items_display_hashref=BuildItemsData(@itemnumbers);
    } else {
        $template->param("too_many_items_display" => scalar(@itemnumbers));
        # Even if we do not display the items, we need the itemnumbers
        $template->param(itemnumbers_array => \@itemnumbers);
    }
# now, build the item form for entering a new item
my @loop_data =();
my $i=0;
my $branch_limit = C4::Context->userenv ? C4::Context->userenv->{"branch"} : "";

my $libraries = Koha::Libraries->search({}, { order_by => ['branchname'] })->unblessed;# build once ahead of time, instead of multiple times later.

# Adding a default choice, in case the user does not want to modify the branch
my $nochange_branch = { branchname => '', value => '', selected => 1 };
unshift (@$libraries, $nochange_branch);

my $pref_itemcallnumber = C4::Context->preference('itemcallnumber');

# Getting list of subfields to keep when restricted batchmod edit is enabled
my $subfieldsToAllowForBatchmod = C4::Context->preference('SubfieldsToAllowForRestrictedBatchmod');
my $allowAllSubfields = (
    not defined $subfieldsToAllowForBatchmod
      or $subfieldsToAllowForBatchmod eq q||
) ? 1 : 0;
my @subfieldsToAllow = split(/ /, $subfieldsToAllowForBatchmod);

foreach my $tag (sort keys %{$tagslib}) {
    # loop through each subfield
    foreach my $subfield (sort keys %{$tagslib->{$tag}}) {
        next if IsMarcStructureInternal( $tagslib->{$tag}{$subfield} );
        next if (not $allowAllSubfields and $restrictededition && !grep { $tag . '$' . $subfield eq $_ } @subfieldsToAllow );
    	next if ($tagslib->{$tag}->{$subfield}->{'tab'} ne "10");
        # barcode is not meant to be batch-modified
        next if $tagslib->{$tag}->{$subfield}->{'kohafield'} eq 'items.barcode';
	my %subfield_data;
 
	my $index_subfield = int(rand(1000000)); 
	if ($subfield eq '@'){
	    $subfield_data{id} = "tag_".$tag."_subfield_00_".$index_subfield;
	} else {
	    $subfield_data{id} = "tag_".$tag."_subfield_".$subfield."_".$index_subfield;
	}
	$subfield_data{tag}        = $tag;
	$subfield_data{subfield}   = $subfield;
	$subfield_data{marc_lib}   ="<span id=\"error$i\" title=\"".$tagslib->{$tag}->{$subfield}->{lib}."\">".$tagslib->{$tag}->{$subfield}->{lib}."</span>";
	$subfield_data{mandatory}  = $tagslib->{$tag}->{$subfield}->{mandatory};
	$subfield_data{repeatable} = $tagslib->{$tag}->{$subfield}->{repeatable};
    my $value;
    if ( $use_default_values) {
	    $value = $tagslib->{$tag}->{$subfield}->{defaultvalue};
	    # get today date & replace YYYY, MM, DD if provided in the default value
            my $today = dt_from_string;
            my $year  = $today->year;
            my $month = $today->month;
            my $day   = $today->day;
            $value =~ s/YYYY/$year/g;
            $value =~ s/MM/$month/g;
            $value =~ s/DD/$day/g;
	}
	$subfield_data{visibility} = "display:none;" if (($tagslib->{$tag}->{$subfield}->{hidden} > 4) || ($tagslib->{$tag}->{$subfield}->{hidden} < -4));
    # testing branch value if IndependentBranches.

	if ( $tagslib->{$tag}->{$subfield}->{authorised_value} ) {
	my @authorised_values;
	my %authorised_lib;
	# builds list, depending on authorised value...

    if ( $tagslib->{$tag}->{$subfield}->{authorised_value} eq "branches" ) {
        foreach my $library (@$libraries) {
            push @authorised_values, $library->{branchcode};
            $authorised_lib{$library->{branchcode}} = $library->{branchname};
        }
        $value = "";
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{authorised_value} eq "itemtypes" ) {
        push @authorised_values, "";
        my $itemtypes = Koha::ItemTypes->search_with_localization;
        while ( my $itemtype = $itemtypes->next ) {
            push @authorised_values, $itemtype->itemtype;
            $authorised_lib{$itemtype->itemtype} = $itemtype->translated_description;
        }
        $value = "";

          #---- class_sources
      }
      elsif ( $tagslib->{$tag}->{$subfield}->{authorised_value} eq "cn_source" ) {
          push @authorised_values, "" unless ( $tagslib->{$tag}->{$subfield}->{mandatory} );
            
          my $class_sources = GetClassSources();
          my $default_source = C4::Context->preference("DefaultClassificationSource");
          
          foreach my $class_source (sort keys %$class_sources) {
              next unless $class_sources->{$class_source}->{'used'} or
                          ($value and $class_source eq $value)      or
                          ($class_source eq $default_source);
              push @authorised_values, $class_source;
              $authorised_lib{$class_source} = $class_sources->{$class_source}->{'description'};
          }
		  $value = '';

          #---- "true" authorised value
      }
      else {
          push @authorised_values, ""; # unless ( $tagslib->{$tag}->{$subfield}->{mandatory} );

          my @avs = Koha::AuthorisedValues->search_with_library_limits(
              {
                  category   => $tagslib->{$tag}->{$subfield}->{authorised_value}
              },
              { order_by => 'lib' },
              $branch_limit
          );
          for my $av ( @avs ) {
              push @authorised_values, $av->authorised_value;
              $authorised_lib{$av->authorised_value} = $av->lib;
          }
          $value="";
      }
        $subfield_data{marc_value} = {
            type    => 'select',
            id      => "tag_".$tag."_subfield_".$subfield."_".$index_subfield,
            name    => "field_value",
            values  => \@authorised_values,
            labels  => \%authorised_lib,
            default => $value,
        };
    # it's a thesaurus / authority field
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{authtypecode} ) {
        $subfield_data{marc_value} = {
            type         => 'text1',
            id           => $subfield_data{id},
            value        => $value,
            authtypecode => $tagslib->{$tag}->{$subfield}->{authtypecode},
        }
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{value_builder} ) { # plugin
        require Koha::FrameworkPlugin;
        my $plugin = Koha::FrameworkPlugin->new( {
            name => $tagslib->{$tag}->{$subfield}->{'value_builder'},
            item_style => 1,
        });
        my $temp;
        my $pars= { dbh => $dbh, record => $temp, tagslib => $tagslib,
            id => $subfield_data{id}, tabloop => \@loop_data };
        $plugin->build( $pars );
        if( !$plugin->errstr ) {
            $subfield_data{marc_value} = {
                type       => 'text2',
                id         => $subfield_data{id},
                value      => $value,
                javascript => $plugin->javascript,
                noclick    => $plugin->noclick,
            };
        } else {
            warn $plugin->errstr;
            $subfield_data{marc_value} = { # supply default input form
                type       => 'text',
                id         => $subfield_data{id},
                value      => $value,
            };
        }
    }
    elsif ( $tag eq '' ) {       # it's an hidden field
            $subfield_data{marc_value} = {
                type       => 'hidden',
                id         => $subfield_data{id},
                value      => $value,
            };
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{'hidden'} ) {   # FIXME: shouldn't input type be "hidden" ?
        $subfield_data{marc_value} = {
                type       => 'text',
                id         => $subfield_data{id},
                value      => $value,
        };
    }
    elsif ( length($value) > 100
            or (C4::Context->preference("marcflavour") eq "UNIMARC" and
                  300 <= $tag && $tag < 400 && $subfield eq 'a' )
            or (C4::Context->preference("marcflavour") eq "MARC21"  and
                  500 <= $tag && $tag < 600                     )
          ) {
        # oversize field (textarea)
        $subfield_data{marc_value} = {
                type       => 'textarea',
                id         => $subfield_data{id},
                value      => $value,
        };
    } else {
        # it's a standard field
        $subfield_data{marc_value} = {
                type       => 'text',
                id         => $subfield_data{id},
                value      => $value,
        };
    }
#   $subfield_data{marc_value}="<input type=\"text\" name=\"field_value\">";
    push (@loop_data, \%subfield_data);
    $i++
  }
} # -- End foreach tag



    # what's the next op ? it's what we are not in : an add if we're editing, otherwise, and edit.
    $template->param(
        item                => \@loop_data,
        notfoundbarcodes    => \@notfoundbarcodes,
        notfounditemnumbers => \@notfounditemnumbers
    );
    $nextop="action"
} # -- End action="show"

$template->param(%$items_display_hashref) if $items_display_hashref;
$template->param(
    op      => $nextop,
);
$template->param( $op => 1 ) if $op;

if ($op eq "action") {

    #my @not_deleted_loop = map{{itemnumber=>$_}}@not_deleted;

    $template->param(
	not_deleted_items => $not_deleted_items,
	deleted_items => $deleted_items,
	delete_records => $del_records,
	deleted_records => $deleted_records,
	not_deleted_loop => \@not_deleted 
    );
}

foreach my $error (@errors) {
    $template->param($error => 1) if $error;
}
$template->param(src => $src);
$template->param(biblionumber => $biblionumber);
output_html_with_http_headers $input, $cookie, $template->output;
exit;


# ---------------- Functions

sub BuildItemsData{
	my @itemnumbers=@_;
		# now, build existiing item list
		my %witness; #---- stores the list of subfields used at least once, with the "meaning" of the code
		my @big_array;
		#---- finds where items.itemnumber is stored
    my (  $itemtagfield,   $itemtagsubfield) = &GetMarcFromKohaField( "items.itemnumber" );
    my ($branchtagfield, $branchtagsubfield) = &GetMarcFromKohaField( "items.homebranch" );
		foreach my $itemnumber (@itemnumbers){
            my $itemdata = Koha::Items->find($itemnumber);
            next unless $itemdata; # Should have been tested earlier, but just in case...
            $itemdata = $itemdata->unblessed;
			my $itemmarc=Item2Marc($itemdata);
			my %this_row;
			foreach my $field (grep {$_->tag() eq $itemtagfield} $itemmarc->fields()) {
				# loop through each subfield
				my $itembranchcode=$field->subfield($branchtagsubfield);
                if ($itembranchcode && C4::Context->preference("IndependentBranches")) {
						#verifying rights
						my $userenv = C4::Context->userenv();
                        unless (C4::Context->IsSuperLibrarian() or (($userenv->{'branch'} eq $itembranchcode))){
								$this_row{'nomod'}=1;
						}
				}
				my $tag=$field->tag();
				foreach my $subfield ($field->subfields) {
					my ($subfcode,$subfvalue)=@$subfield;
					next if ($tagslib->{$tag}->{$subfcode}->{tab} ne 10 
							&& $tag        ne $itemtagfield 
							&& $subfcode   ne $itemtagsubfield);

					$witness{$subfcode} = $tagslib->{$tag}->{$subfcode}->{lib} if ($tagslib->{$tag}->{$subfcode}->{tab}  eq 10);
					if ($tagslib->{$tag}->{$subfcode}->{tab}  eq 10) {
						$this_row{$subfcode}=GetAuthorisedValueDesc( $tag,
									$subfcode, $subfvalue, '', $tagslib) 
									|| $subfvalue;
					}

					$this_row{itemnumber} = $subfvalue if ($tag eq $itemtagfield && $subfcode eq $itemtagsubfield);
				}
			}

            # grab title, author, and ISBN to identify bib that the item
            # belongs to in the display
            my $biblio = Koha::Biblios->find( $itemdata->{biblionumber} );
            $this_row{title}        = $biblio->title;
            $this_row{author}       = $biblio->author;
            $this_row{isbn}         = $biblio->biblioitem->isbn;
            $this_row{biblionumber} = $biblio->biblionumber;
            $this_row{holds}        = $biblio->holds->count;
            $this_row{item_holds}   = Koha::Holds->search( { itemnumber => $itemnumber } )->count;
            $this_row{item}         = Koha::Items->find($itemnumber);

			if (%this_row) {
				push(@big_array, \%this_row);
			}
		}
		@big_array = sort {$a->{0} cmp $b->{0}} @big_array;

		# now, construct template !
		# First, the existing items for display
		my @item_value_loop;
		my @witnesscodessorted=sort keys %witness;
		for my $row ( @big_array ) {
			my %row_data;
			my @item_fields = map +{ field => $_ || '' }, @$row{ @witnesscodessorted };
			$row_data{item_value} = [ @item_fields ];
			$row_data{itemnumber} = $row->{itemnumber};
			#reporting this_row values
			$row_data{'nomod'} = $row->{'nomod'};
      $row_data{bibinfo} = $row->{bibinfo};
      $row_data{author} = $row->{author};
      $row_data{title} = $row->{title};
      $row_data{isbn} = $row->{isbn};
      $row_data{biblionumber} = $row->{biblionumber};
      $row_data{holds}        = $row->{holds};
      $row_data{item_holds}   = $row->{item_holds};
      $row_data{item}         = $row->{item};
      $row_data{safe_to_delete} = $row->{item}->safe_to_delete;
      my $is_on_loan = C4::Circulation::IsItemIssued( $row->{itemnumber} );
      $row_data{onloan} = $is_on_loan ? 1 : 0;
			push(@item_value_loop,\%row_data);
		}
		my @header_loop=map { { header_value=> $witness{$_}} } @witnesscodessorted;

    my @cannot_be_deleted = map {
        $_->{safe_to_delete} == 1 ? () : $_->{item}->barcode
    } @item_value_loop;
    return {
        item_loop        => \@item_value_loop,
        cannot_be_deleted => \@cannot_be_deleted,
        item_header_loop => \@header_loop
    };
}

#BE WARN : it is not the general case 
# This function can be OK in the item marc record special case
# Where subfield is not repeated
# And where we are sure that field should correspond
# And $tag>10
sub UpdateMarcWith {
  my ($marcfrom,$marcto)=@_;
    my (  $itemtag,   $itemtagsubfield) = &GetMarcFromKohaField( "items.itemnumber" );
    my $fieldfrom=$marcfrom->field($itemtag);
    my @fields_to=$marcto->field($itemtag);
    my $modified = 0;

    return $modified unless $fieldfrom;

    foreach my $subfield ( $fieldfrom->subfields() ) {
        foreach my $field_to_update ( @fields_to ) {
            if ( $subfield->[1] ) {
                unless ( $field_to_update->subfield($subfield->[0]) eq $subfield->[1] ) {
                    $modified++;
                    $field_to_update->update( $subfield->[0] => $subfield->[1] );
                }
            }
            else {
                $modified++;
                $field_to_update->delete_subfield( code => $subfield->[0] );
            }
        }
    }
    return $modified;
}

sub find_value {
    my ($tagfield,$insubfield,$record) = @_;
    my $result;
    my $indicator;
    foreach my $field ($record->field($tagfield)) {
        my @subfields = $field->subfields();
        foreach my $subfield (@subfields) {
            if (@$subfield[0] eq $insubfield) {
                $result .= @$subfield[1];
                $indicator = $field->indicator(1).$field->indicator(2);
            }
        }
    }
    return($indicator,$result);
}
