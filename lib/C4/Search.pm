package C4::Search;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA

use Koha;
no warnings qw(uninitialized);
require Exporter;
use C4::Context;
use C4::Biblio;    # GetMarcFromKohaField, GetBiblioData
use C4::Koha;
use Lingua::Stem;
use C4::Search::PazPar2;
use XML::Simple;
use C4::Dates qw(format_date);
use C4::XSLT;
use C4::Branch;
use URI::Escape;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

# set the version for version checking
BEGIN {
    $VERSION = 3.01;
    $DEBUG = ($ENV{DEBUG}) ? 1 : 0;
}

=head1 NAME

C4::Search - Functions for searching the Koha catalog.

=head1 SYNOPSIS

See opac/opac-search.pl or catalogue/search.pl for example of usage

=head1 DESCRIPTION

This module provides searching functions for Koha's bibliographic databases

=head1 FUNCTIONS

=cut

@ISA    = qw(Exporter);
@EXPORT = qw(
  &FindDuplicate
  &SimpleSearch
  &searchResults
  &getRecords
  &buildQuery
);

# make all your functions, whether exported or not;

=head2 FindDuplicate

($biblionumber,$biblionumber,$title) = FindDuplicate($record);

This function attempts to find duplicate records using a hard-coded, fairly simplistic algorithm

=cut

sub FindDuplicate {
    my ($record) = @_;
    my $dbh = C4::Context->dbh;
    my $result = TransformMarcToKoha( $dbh, $record, '' );
    my $sth;
    my $query;
    my $search;
    my $type;
    my ( $biblionumber, $title );

    # search duplicate on ISBN, easy and fast..
    # ... normalize first
    if ( $result->{isbn} ) {
        $result->{isbn} =~ s/\(.*$//;
        $result->{isbn} =~ s/\s+$//;
        $query = "isbn=$result->{isbn}";
    }
    else {
        $result->{title} =~ s /\\//g;
        $result->{title} =~ s /\"//g;
        $result->{title} =~ s /\(//g;
        $result->{title} =~ s /\)//g;

        # FIXME: instead of removing operators, could just do
        # quotes around the value
        $result->{title} =~ s/(and|or|not)//g;
        $query = "ti,ext=$result->{title}";
        $query .= " and itemtype=$result->{itemtype}"
          if ( $result->{itemtype} );
        if   ( $result->{author} ) {
            $result->{author} =~ s /\\//g;
            $result->{author} =~ s /\"//g;
            $result->{author} =~ s /\(//g;
            $result->{author} =~ s /\)//g;

            # remove valid operators
            $result->{author} =~ s/(and|or|not)//g;
            $query .= " and au,ext=$result->{author}";
        }
    }

    # FIXME: add error handling
    my ( $error, $searchresults ) = SimpleSearch($query); # FIXME :: hardcoded !
    my @results;
    foreach my $possible_duplicate_record (@$searchresults) {
        my $marcrecord =
          MARC::Record->new_from_xml($possible_duplicate_record);
        my $result = TransformMarcToKoha( $dbh, $marcrecord, '' );

        # FIXME :: why 2 $biblionumber ?
        if ($result) {
            push @results, $result->{'biblionumber'};
            push @results, $result->{'title'};
        }
    }
    return @results;
}

=head2 SimpleSearch

( $error, $results, $total_hits ) = SimpleSearch( $query, $offset, $max_results, [@servers] );

This function provides a simple search API on the bibliographic catalog

=over 2

=item C<input arg:>

    * $query can be a simple keyword or a complete CCL query
    * @servers is optional. Defaults to biblioserver as found in koha-conf.xml
    * $offset - If present, represents the number of records at the beggining to omit. Defaults to 0
    * $max_results - if present, determines the maximum number of records to fetch. undef is All. defaults to undef.


=item C<Output:>

    * $error is a empty unless an error is detected
    * \@results is an array of records.
    * $total_hits is the number of hits that would have been returned with no limit

=item C<usage in the script:>

=back

my ( $error, $marcresults, $total_hits ) = SimpleSearch($query);

if (defined $error) {
    $template->param(query_error => $error);
    warn "error: ".$error;
    output_html_with_http_headers $input, $cookie, $template->output;
    exit;
}

my $hits = scalar @$marcresults;
my @results;

for my $i (0..$hits) {
    my %resultsloop;
    my $marcrecord = MARC::File::XML::decode($marcresults->[$i], 'UTF-8');
    my $biblio = TransformMarcToKoha(C4::Context->dbh,$marcrecord,'');

    #build the hash for the template.
    $resultsloop{title}           = $biblio->{'title'};
    $resultsloop{subtitle}        = $biblio->{'subtitle'};
    $resultsloop{biblionumber}    = $biblio->{'biblionumber'};
    $resultsloop{author}          = $biblio->{'author'};
    $resultsloop{publishercode}   = $biblio->{'publishercode'};
    $resultsloop{publicationyear} = $biblio->{'publicationyear'};

    push @results, \%resultsloop;
}

$template->param(result=>\@results);

=cut

sub SimpleSearch {
    my ( $query, $offset, $max_results, $servers )  = @_;
    
    # FIXME hardcoded value. See catalog/search.pl & opac-search.pl too.
    my @servers = defined ( $servers ) ? @$servers : ( "biblioserver" );
    my @results;
    my @zoom_queries;
    my @tmpresults;
    my @zconns;
    my $total_hits;
    return ( "No query entered", undef, undef ) unless $query;

    # Initialize & Search Zebra
    for ( my $i = 0 ; $i < @servers ; $i++ ) {
        eval {
            $zconns[$i] = C4::Context->Zconn( $servers[$i], 1 );
            $zoom_queries[$i] = new ZOOM::Query::CCL2RPN( $query, $zconns[$i]);
            $tmpresults[$i] = $zconns[$i]->search( $zoom_queries[$i] );

            # error handling
            my $error =
                $zconns[$i]->errmsg() . " ("
                . $zconns[$i]->errcode() . ") "
                . $zconns[$i]->addinfo() . " "
                . $zconns[$i]->diagset();

            return ( $error, undef, undef ) if $zconns[$i]->errcode();
        };
        if ($@) {
            # caught a ZOOM::Exception
            my $error =
                $@->message() . " ("
                . $@->code() . ") "
                . $@->addinfo() . " "
                . $@->diagset();
            warn $error;
            return ( $error, undef, undef );
        }
    }
    while ( ( my $i = ZOOM::event( \@zconns ) ) != 0 ) {
        my $event = $zconns[ $i - 1 ]->last_event();
        if ( $event == ZOOM::Event::ZEND ) {

            my $first_record = defined( $offset ) ? $offset+1 : 1;
            my $hits = $tmpresults[ $i - 1 ]->size();
            $total_hits += $hits;
            my $last_record = $hits;
            if ( defined $max_results && $offset + $max_results < $hits ) {
                $last_record  = $offset + $max_results;
            }
            for my $j ( $first_record..$last_record ) {
                my $record = $tmpresults[ $i - 1 ]->record( $j-1 )->raw(); # 0 indexed
                push @results, $record;
            }
        }
    }

    foreach my $result (@tmpresults) {
        $result->destroy();
    }
    foreach my $zoom_query (@zoom_queries) {
        $zoom_query->destroy();
    }

    return ( undef, \@results, $total_hits );
}

sub getFacets {
    my $facets;
    if ( C4::Context->preference("marcflavour") eq "UNIMARC" ) {
        $facets = [
            {
                link_value  => 'su-to',
                label_value => 'Topics',
                tags        =>
                  [ '600', '601', '602', '603', '604', '605', '606', '610' ],
                subfield => 'a',
            },
            {
                link_value  => 'su-geo',
                label_value => 'Places',
                tags        => ['651'],
                subfield    => 'a',
            },
            {
                link_value  => 'su-ut',
                label_value => 'Titles',
                tags        => [ '500', '501', '502', '503', '504', ],
                subfield    => 'a',
            },
            {
                link_value  => 'au',
                label_value => 'Authors',
                tags        => [ '700', '701', '702', ],
                subfield    => 'a',
            },
            {
                link_value  => 'se',
                label_value => 'Series',
                tags        => ['225'],
                subfield    => 'a',
            },
            ];

            my $library_facet;

            $library_facet = {
                link_value  => 'branch',
                label_value => 'Libraries',
                tags        => [ '995', ],
                subfield    => 'b',
                expanded    => '1',
            };
            push @$facets, $library_facet unless C4::Context->preference("singleBranchMode");
    }
    else {
        $facets = [
            {
                link_value  => 'su-to',
                label_value => 'Topics',
                tags        => ['650'],
                subfield    => 'a',
            },
            {
                link_value  => 'fixed',
                label_value => 'Formats',
                tags        => ['007','008'],
                span        => ['l-format:007:0:1','ctype:008:24:27','e-format:008:26:26','ff8-23:008:23:23'],
            },
            {
                link_value  => 'su-geo',
                label_value => 'Places',
                tags        => ['651'],
                subfield    => 'a',
            },
            {
                link_value  => 'su-ut',
                label_value => 'Titles',
                tags        => ['630'],
                subfield    => 'a',
            },
            {
                link_value  => 'au',
                label_value => 'Authors',
                tags        => [ '100', '110', '700', ],
                subfield    => 'a',
            },
            {
                link_value  => 'se',
                label_value => 'Series',
                tags        => [ '440', '490', ],
                subfield    => 'a',
            },
            ];
            my $library_facet;
            $library_facet = {
                link_value  => 'branch',
                label_value => 'Libraries',
                tags        => [ '952', ],
                subfield    => 'b',
                expanded    => '1',
            };
            push @$facets, $library_facet unless C4::Context->preference("singleBranchMode");
    }
    return $facets;
}

=head2 getRecords

( undef, $results_hashref, \@facets_loop ) = getRecords (

        $koha_query,       $simple_query, $sort_by_ref,    $servers_ref,
        $results_per_page, $offset,       $expanded_facet, $branches,
        $query_type,       $scan
    );

The all singing, all dancing, multi-server, asynchronous, scanning,
searching, record nabbing, facet-building 

See verbse embedded documentation.

=cut

sub getRecords {
    my (
        $koha_query,       $simple_query, $sort_by_ref,    $servers_ref,
        $results_per_page, $offset,       $expanded_facet, $branches,
        $query_type,       $scan
    ) = @_;

    my @servers = @$servers_ref;
    my @sort_by = @$sort_by_ref;

    # Initialize variables for the ZOOM connection and results object
    my $zconn;
    my @zconns;
    my @results;
    my $results_hashref = ();

    # Initialize variables for the faceted results objects
    my $facets_counter = ();
    my $facets_info    = ();
    my $facets         = getFacets();

    my @facets_loop;    # stores the ref to array of hashes for template facets loop

    ### LOOP THROUGH THE SERVERS
    for ( my $i = 0 ; $i < @servers ; $i++ ) {
        $zconns[$i] = C4::Context->Zconn( $servers[$i], 1 );

    ###This is to address extraneous "and" operators generated in the zebra query
        $koha_query    =~ s{(\band\b\s+)(?=\1)}{}g;

# perform the search, create the results objects
# if this is a local search, use the $koha-query, if it's a federated one, use the federated-query
        my $query_to_use = ($servers[$i] =~ /biblioserver/) ? $koha_query : $simple_query;

        #$query_to_use = $simple_query if $scan;
        warn $simple_query if ( $scan and $DEBUG );

        # Check if we've got a query_type defined, if so, use it
        eval {
            if ($query_type) {
                if ($query_type =~ /^ccl/) {
                    $query_to_use =~ s/\:/\=/g;    # change : to = last minute (FIXME)
                    $results[$i] = $zconns[$i]->search(new ZOOM::Query::CCL2RPN($query_to_use, $zconns[$i]));
                } elsif ($query_type =~ /^cql/) {
                    $results[$i] = $zconns[$i]->search(new ZOOM::Query::CQL($query_to_use, $zconns[$i]));
                } elsif ($query_type =~ /^pqf/) {
                    $results[$i] = $zconns[$i]->search(new ZOOM::Query::PQF($query_to_use, $zconns[$i]));
                } else {
                    warn "Unknown query_type '$query_type'.  Results undetermined.";
                }
            } elsif ($scan) {
                    $results[$i] = $zconns[$i]->scan(  new ZOOM::Query::CCL2RPN($query_to_use, $zconns[$i]));
            } else {
                    $results[$i] = $zconns[$i]->search(new ZOOM::Query::CCL2RPN($query_to_use, $zconns[$i]));
            }
        };
        if ($@) {
            warn "WARNING: query problem with $query_to_use " . $@;
        }

        # Concatenate the sort_by limits and pass them to the results object
        # Note: sort will override rank
        my $sort_by;
        foreach my $sort (@sort_by) {
            if ( $sort eq "author_az" ) {
                $sort_by .= "1=1003 <i ";
            }
            elsif ( $sort eq "author_za" ) {
                $sort_by .= "1=1003 >i ";
            }
            elsif ( $sort eq "popularity_asc" ) {
                $sort_by .= "1=9003 <i ";
            }
            elsif ( $sort eq "popularity_dsc" ) {
                $sort_by .= "1=9003 >i ";
            }
            elsif ( $sort eq "call_number_asc" ) {
                $sort_by .= "1=8007  <i ";
            }
            elsif ( $sort eq "call_number_dsc" ) {
                $sort_by .= "1=8007 >i ";
            }
            elsif ( $sort eq "pubdate_asc" ) {
                $sort_by .= "1=31 <i ";
            }
            elsif ( $sort eq "pubdate_dsc" ) {
                $sort_by .= "1=31 >i ";
            }
            elsif ( $sort eq "acqdate_asc" ) {
                $sort_by .= "1=32 <i ";
            }
            elsif ( $sort eq "acqdate_dsc" ) {
                $sort_by .= "1=32 >i ";
            }
            elsif ( $sort eq "title_az" ) {
                $sort_by .= "1=4 <i ";
            }
            elsif ( $sort eq "title_za" ) {
                $sort_by .= "1=4 >i ";
            }
            else {
                warn "Ignoring unrecognized sort '$sort' requested" if $sort_by;
            }
        }
        if ($sort_by) {
            if ( $results[$i]->sort( "yaz", $sort_by ) < 0 ) {
                warn "WARNING sort $sort_by failed";
            }
        }
    }    # finished looping through servers

    # The big moment: asynchronously retrieve results from all servers
    while ( ( my $i = ZOOM::event( \@zconns ) ) != 0 ) {
        my $ev = $zconns[ $i - 1 ]->last_event();
        if ( $ev == ZOOM::Event::ZEND ) {
            next unless $results[ $i - 1 ];
            my $size = $results[ $i - 1 ]->size();

            my %format_tie; ##used to verify fixed-field format for facets
            if ( $size > 0 ) {
                my $results_hash;

                # loop through the results
                $results_hash->{'hits'} = $size;
                my $times;
                if ( $offset + $results_per_page <= $size ) {
                    $times = $offset + $results_per_page;
                }
                else {
                    $times = $size;
                }
                for ( my $j = $offset ; $j < $times ; $j++ ) {
                    my $records_hash;
                    my $record;
                    my $facet_record;

                    ## Check if it's an index scan
                    if ($scan) {
                        my ( $term, $occ ) = $results[ $i - 1 ]->term($j);

                 # here we create a minimal MARC record and hand it off to the
                 # template just like a normal result ... perhaps not ideal, but
                 # it works for now
                        my $tmprecord = MARC::Record->new();
                        $tmprecord->encoding('UTF-8');
                        my $tmptitle;
                        my $tmpauthor;

                # the minimal record in author/title (depending on MARC flavour)
                        if (C4::Context->preference("marcflavour") eq "UNIMARC") {
                            $tmptitle = MARC::Field->new('200',' ',' ', a => $term, f => $occ);
                            $tmprecord->append_fields($tmptitle);
                        } else {
                            $tmptitle  = MARC::Field->new('245',' ',' ', a => $term,);
                            $tmpauthor = MARC::Field->new('100',' ',' ', a => $occ,);
                            $tmprecord->append_fields($tmptitle);
                            $tmprecord->append_fields($tmpauthor);
                        }
                        $results_hash->{'RECORDS'}[$j] = $tmprecord->as_xml();
                    }

                    # not an index scan
                    else {
                        $record = $results[ $i - 1 ]->record($j)->raw();

                        # warn "RECORD $j:".$record;
                        $results_hash->{'RECORDS'}[$j] = $record;

                        # Fill the facets while we're looping, but only for the biblioserver
                        if($servers[ $i - 1 ] =~ /biblioserver/){
                            $facet_record = eval { MARC::Record->new_from_xml($record,'UTF-8') };
                            if($@){
                                warn "Bad record returned. $@";
                                next;
                            }
                            #warn $servers[$i-1]."\n".$record; #.$facet_record->title();
                        }

                        if ($facet_record) {
                            for ( my $k = 0 ; $k <= @$facets ; $k++ ) {
                                ($facets->[$k]) or next;
                                my @fields = map {$facet_record->field($_)} @{$facets->[$k]->{'tags'}} ;
                                for my $field (@fields) {
                                    if ($field->tag gt '099') {
                                        my @subfields = $field->subfields();
                                        for my $subfield (@subfields) {
                                            my ( $code, $data ) = @$subfield;
                                            ($code eq $facets->[$k]->{'subfield'}) or next;
                                            $facets_counter->{ $facets->[$k]->{'link_value'} }->{$data}++;
                                        }
                                    } else {
                                        for my $fixed_field (@{$facets->[$k]{'span'}} ){  
                                            my ($alt_link_value,$alt_tag,$first, $last) = split(/:/, $fixed_field);
                                            my $data = substr($field->data, $first, $last-$first+1) unless length($field->data) < $first;
                                            $data =~ s{^\+|\s+$|\d{2,}|\|}{}g;
                                            push @{$format_tie{$data}},$alt_link_value,$alt_tag,$data if ($data ne undef && ! exists $format_tie{$data} );
                                            $facets_counter->{$facets->[$k]{'link_value'}}{$data}++ if exists $format_tie{$data};
                                        }
                                    }
                                }
                                $facets_info->{ $facets->[$k]->{'link_value'} }->{'label_value'} =
                                    $facets->[$k]->{'label_value'};
                                $facets_info->{ $facets->[$k]->{'link_value'} }->{'expanded'} =
                                    $facets->[$k]->{'expanded'};
                            }
                        }
                    }
                }
                $results_hashref->{ $servers[ $i - 1 ] } = $results_hash;
            }

            # warn "connection ", $i-1, ": $size hits";
            # warn $results[$i-1]->record(0)->render() if $size > 0;
            # BUILD FACETS
            if ( $servers[ $i - 1 ] =~ /biblioserver/ ) {
                for my $link_value (
                    sort { $facets_counter->{$b} <=> $facets_counter->{$a} }
                        keys %$facets_counter )
                {
                    my $expandable;
                    my $number_of_facets;
                    my @this_facets_array;
                    for my $one_facet (
                        sort {
                             $facets_counter->{$link_value}->{$b}
                         <=> $facets_counter->{$link_value}->{$a}
                        } keys %{ $facets_counter->{$link_value} }
                      )
                    {
                        $number_of_facets++;
                        if (   ( $number_of_facets < 6 )
                            || ( $expanded_facet eq $link_value )
                            || ( $facets_info->{$link_value}->{'expanded'} ) )
                        {

                      # Sanitize the link value ), ( will cause errors with CCL,
                            my $facet_link_value = $one_facet;
                            $facet_link_value =~ s/(\(|\))/ /g;

                            # fix the length that will display in the label,
                            my $facet_label_value = $one_facet;
                            $facet_label_value =
                              substr( $one_facet, 0, 20 ) . "..."
                              unless length($facet_label_value) <= 20;

                            # if it's a branch, label by the name, not the code,
                            if ( $link_value =~ /branch/ ) {
                                $facet_label_value =
                                  $branches->{$one_facet}->{'branchname'};
                            }
                             elsif($link_value eq 'fixed'){
                              
                                  my $authval;
                                  if ($format_tie{$facet_link_value}[0] eq 'l-format' && $format_tie{$facet_link_value}[2] eq $facet_link_value){
                                     $authval = GetAuthorisedValue('HINGS_PF', $facet_link_value) ;
                                   }
                                  if ($format_tie{$facet_link_value}[0] eq 'ctype' && $format_tie{$facet_link_value}[2] eq $facet_link_value){
                                    $authval = GetAuthorisedValue('CTYPE', $facet_link_value);
                                   }   
                                  if ($format_tie{$facet_link_value}[0] eq 'ff8-23' && $format_tie{$facet_link_value}[2] eq $facet_link_value){
                                    $authval = GetAuthorisedValue('CTYPE', $facet_link_value);
                                  } 
                                  if ($format_tie{$facet_link_value}[0] eq 'e-format' && $format_tie{$facet_link_value}[2] eq $facet_link_value){
                                     $authval = GetAuthorisedValue('ETYPE', $facet_link_value) ;
                                   }                                                                
                                  $facet_label_value = ($authval) ? $authval->{lib} : undef;
                             }

                          # but we're down with the whole label being in the link's title.
                            push @this_facets_array, {
                                facet_count       => $facets_counter->{$link_value}->{$facet_link_value},
                                facet_label_value => $facet_label_value,
                                facet_title_value => $one_facet,
                                facet_link_value  => $facet_link_value,
                                type_link_value   => $link_value eq 'fixed' ? $format_tie{$facet_link_value}[0]: $link_value ,
                            };
                        }
                    }
                    # handle expanded option
                    unless ( $facets_info->{$link_value}->{'expanded'} ) {
                        $expandable = 1
                          if ( ( $number_of_facets > 6 )
                            && ( $expanded_facet ne $link_value ) );
                    }
                    push @facets_loop, {
                        type_link_value => $link_value,
                        type_id         => $link_value . "_id",
                        "type_label_" . $facets_info->{$link_value}->{'label_value'} => 1, 
                        label      => $facets_info->{$link_value}->{'label_value'},
                        facets     => \@this_facets_array,
                        expandable => $expandable,
                        expand     => $link_value,
                        offset     => $offset,
                    } unless ( ($facets_info->{$link_value}->{'label_value'} =~ /Libraries/) and (C4::Context->preference('singleBranchMode')) );
                }
            }
        }
    }
    return ( undef, $results_hashref, \@facets_loop );
}

sub pazGetRecords {
    my (
        $koha_query,       $simple_query, $sort_by_ref,    $servers_ref,
        $results_per_page, $offset,       $expanded_facet, $branches,
        $query_type,       $scan
    ) = @_;

    my $paz = C4::Search::PazPar2->new(C4::Context->config('pazpar2url'));
    $paz->init();
    $paz->search($simple_query);
    sleep 1;   # FIXME: WHY?

    # do results
    my $results_hashref = {};
    my $stats = XMLin($paz->stat);
    my $results = XMLin($paz->show($offset, $results_per_page, 'work-title:1'), forcearray => 1);
   
    # for a grouped search result, the number of hits
    # is the number of groups returned; 'bib_hits' will have
    # the total number of bibs. 
    $results_hashref->{'biblioserver'}->{'hits'} = $results->{'merged'}->[0];
    $results_hashref->{'biblioserver'}->{'bib_hits'} = $stats->{'hits'};

    HIT: foreach my $hit (@{ $results->{'hit'} }) {
        my $recid = $hit->{recid}->[0];

        my $work_title = $hit->{'md-work-title'}->[0];
        my $work_author;
        if (exists $hit->{'md-work-author'}) {
            $work_author = $hit->{'md-work-author'}->[0];
        }
        my $group_label = (defined $work_author) ? "$work_title / $work_author" : $work_title;

        my $result_group = {};
        $result_group->{'group_label'} = $group_label;
        $result_group->{'group_merge_key'} = $recid;

        my $count = 1;
        if (exists $hit->{count}) {
            $count = $hit->{count}->[0];
        }
        $result_group->{'group_count'} = $count;

        for (my $i = 0; $i < $count; $i++) {
            # FIXME -- may need to worry about diacritics here
            my $rec = $paz->record($recid, $i);
            push @{ $result_group->{'RECORDS'} }, $rec;
        }

        push @{ $results_hashref->{'biblioserver'}->{'GROUPS'} }, $result_group;
    }
    
    # pass through facets
    my $termlist_xml = $paz->termlist('author,subject');
    my $terms = XMLin($termlist_xml, forcearray => 1);
    my @facets_loop = ();
    #die Dumper($results);
#    foreach my $list (sort keys %{ $terms->{'list'} }) {
#        my @facets = ();
#        foreach my $facet (sort @{ $terms->{'list'}->{$list}->{'term'} } ) {
#            push @facets, {
#                facet_label_value => $facet->{'name'}->[0],
#            };
#        }
#        push @facets_loop, ( {
#            type_label => $list,
#            facets => \@facets,
#        } );
#    }

    return ( undef, $results_hashref, \@facets_loop );
}

# STOPWORDS
sub _remove_stopwords {
    my ( $operand, $index ) = @_;
    my @stopwords_removed;

    # phrase and exact-qualified indexes shouldn't have stopwords removed
    if ( $index !~ m/phr|ext/ ) {

# remove stopwords from operand : parse all stopwords & remove them (case insensitive)
#       we use IsAlpha unicode definition, to deal correctly with diacritics.
#       otherwise, a French word like "leçon" woudl be split into "le" "çon", "le"
#       is a stopword, we'd get "çon" and wouldn't find anything...
		foreach ( keys %{ C4::Context->stopwords } ) {
			next if ( $_ =~ /(and|or|not)/ );    # don't remove operators
			if ( my ($matched) = ($operand =~
				/(\P{IsAlnum}\Q$_\E\P{IsAlnum}|^\Q$_\E\P{IsAlnum}|\P{IsAlnum}\Q$_\E$|^\Q$_\E$)/gi) )
			{
				$operand =~ s/\Q$matched\E/ /gi;
				push @stopwords_removed, $_;
			}
		}
	}
    return ( $operand, \@stopwords_removed );
}

# TRUNCATION
sub _detect_truncation {
    my ( $operand, $index ) = @_;
    my ( @nontruncated, @righttruncated, @lefttruncated, @rightlefttruncated,
        @regexpr );
    $operand =~ s/^ //g;
    my @wordlist = split( /\s/, $operand );
    foreach my $word (@wordlist) {
        if ( $word =~ s/^\*([^\*]+)\*$/$1/ ) {
            push @rightlefttruncated, $word;
        }
        elsif ( $word =~ s/^\*([^\*]+)$/$1/ ) {
            push @lefttruncated, $word;
        }
        elsif ( $word =~ s/^([^\*]+)\*$/$1/ ) {
            push @righttruncated, $word;
        }
        elsif ( index( $word, "*" ) < 0 ) {
            push @nontruncated, $word;
        }
        else {
            push @regexpr, $word;
        }
    }
    return (
        \@nontruncated,       \@righttruncated, \@lefttruncated,
        \@rightlefttruncated, \@regexpr
    );
}

# STEMMING
sub _build_stemmed_operand {
    my ($operand) = @_;
    my $stemmed_operand;

    # If operand contains a digit, it is almost certainly an identifier, and should
    # not be stemmed.  This is particularly relevant for ISBNs and ISSNs, which
    # can contain the letter "X" - for example, _build_stemmend_operand would reduce 
    # "014100018X" to "x ", which for a MARC21 database would bring up irrelevant
    # results (e.g., "23 x 29 cm." from the 300$c).  Bug 2098.
    return $operand if $operand =~ /\d/;

# FIXME: the locale should be set based on the user's language and/or search choice
    my $stemmer = Lingua::Stem->new( -locale => 'EN-US' );

# FIXME: these should be stored in the db so the librarian can modify the behavior
    $stemmer->add_exceptions(
        {
            'and' => 'and',
            'or'  => 'or',
            'not' => 'not',
        }
    );
    my @words = split( / /, $operand );
    my $stems = $stemmer->stem(@words);
    for my $stem (@$stems) {
        $stemmed_operand .= "$stem";
        $stemmed_operand .= "?"
          unless ( $stem =~ /(and$|or$|not$)/ ) || ( length($stem) < 3 );
        $stemmed_operand .= " ";
    }
    warn "STEMMED OPERAND: $stemmed_operand" if $DEBUG;
    return $stemmed_operand;
}

# FIELD WEIGHTING
sub _build_weighted_query {

# FIELD WEIGHTING - This is largely experimental stuff. What I'm committing works
# pretty well but could work much better if we had a smarter query parser
    my ( $operand, $stemmed_operand, $index ) = @_;
    $index ||= 'kw';
    my $stemming      = C4::Context->preference("QueryStemming")     || 0;
    my $weight_fields = C4::Context->preference("QueryWeightFields") || 0;
    my $fuzzy_enabled = C4::Context->preference("QueryFuzzy")        || 0;
    my $adj_rel_rank  = C4::Context->preference("AdjustRelevancyRanking");

    my $weighted_query .= "(rk=(";    # Specifies that we're applying rank

    # Keyword, or, no index specified
    if ( $index eq 'kw' ) {
        $weighted_query .= qq/ (Title-cover,r1="$operand" and $adj_rel_rank ) or /
            if ( $adj_rel_rank );
        $weighted_query .=
          "Title-cover,ext,r1=\"$operand\"";    # exact title-cover
        $weighted_query .= " or ti,ext,r2=\"$operand\"";    # exact title
        $weighted_query .= " or ti,phr,r3=\"$operand\"";    # phrase title
          #$weighted_query .= " or any,ext,r4=$operand";               # exact any
          #$weighted_query .=" or kw,wrdl,r5=\"$operand\"";            # word list any
        $weighted_query .= " or wrdl,fuzzy,r8=\"$operand\""
          if $fuzzy_enabled;    # add fuzzy, word list
        $weighted_query .= " or wrdl,right-Truncation,r9=\"$stemmed_operand\""
          if ( $stemming and $stemmed_operand )
          ;                     # add stemming, right truncation
        $weighted_query .= " or wrdl,r9=\"$operand\"";

        # embedded sorting: 0 a-z; 1 z-a
        # $weighted_query .= ") or (sort1,aut=1";
    }

    # Barcode searches should skip this process
    elsif ( $index eq 'bc' ) {
        $weighted_query .= "bc=\"$operand\"";
    }
    elsif ($index eq 'bcbib') {
       my($bc,$bib) = split(/\|/,$operand,2);
       $weighted_query .= "bc=\"$bc\")) or (rk=(biblionumber=\"$bib\"";
    }
    elsif ($index eq 'sn') { # from advanced search only, exact biblionumber
       $weighted_query .= "biblionumber=\"$operand\"";
    }

    # Authority-number searches should skip this process
    elsif ( $index eq 'an' ) {
        $weighted_query .= "an=\"$operand\"";
    }

    # If the index already has more than one qualifier, wrap the operand
    # in quotes and pass it back (assumption is that the user knows what they
    # are doing and won't appreciate us mucking up their query
    elsif ( $index =~ ',' ) {
        $weighted_query .= " $index=\"$operand\"";
    }
    elsif ( $index eq 'ti' ){
        $weighted_query .= qq/ (Title-cover,r1="$operand" and $adj_rel_rank ) or /
            if ( $adj_rel_rank );
        $weighted_query .= "(Title-cover,r2=\"$operand\")";
        $weighted_query .= " or ti,r7=\"$operand\"";
        $weighted_query .= " or ti,phr,r7=\"$operand\"";
        $weighted_query .= " or ti,wrdl,r7=\"$operand\"";
    }
    #TODO: build better cases based on specific search indexes
    else {
        $weighted_query .= qq/ (Title-cover,r1="$operand" and $adj_rel_rank ) or /
            if ( $adj_rel_rank );
        $weighted_query .= " $index,ext,r1=\"$operand\"";    # exact index
          #$weighted_query .= " or (title-sort-az=0 or $index,startswithnt,st-word,r3=$operand #)";
        $weighted_query .= " or $index,phr,r3=\"$operand\"";    # phrase index
        $weighted_query .=
          " or $index,rt,wrdl,r3=\"$operand\"";    # word list index
    }

    $weighted_query .= "))"; # close rank specification
    $weighted_query = "ln,rtrn=$operand" if ($index eq "ln");
    return $weighted_query;
}

=head2 buildQuery

( $error, $query,
$simple_query, $query_cgi,
$query_desc, $limit,
$limit_cgi, $limit_desc,
$stopwords_removed, $query_type ) = getRecords ( $operators, $operands, $indexes, $limits, $sort_by, $scan);

Build queries and limits in CCL, CGI, Human,
handle truncation, stemming, field weighting, stopwords, fuzziness, etc.

See verbose embedded documentation.


=cut

sub buildQuery {
    my ( $operators, $operands, $indexes, $limits, $sort_by, $scan ) = @_;

    warn "---------\nEnter buildQuery\n---------" if $DEBUG;

    # dereference
    my @operators = $operators ? @$operators : ();
    my @indexes   = $indexes   ? @$indexes   : ();
    my @operands  = $operands  ? @$operands  : ();
    my @limits    = $limits    ? @$limits    : ();
    my @sort_by   = $sort_by   ? @$sort_by   : ();

    my $stemming         = C4::Context->preference("QueryStemming")        || 0;
    my $auto_truncation  = C4::Context->preference("QueryAutoTruncate")    || 0;
    my $weight_fields    = C4::Context->preference("QueryWeightFields")    || 0;
    my $fuzzy_enabled    = C4::Context->preference("QueryFuzzy")           || 0;
    my $remove_stopwords = C4::Context->preference("QueryRemoveStopwords") || 0;

    my $query        = $operands[0];
    my $simple_query = $operands[0];

    # initialize the variables we're passing back
    my $query_cgi;
    my $query_desc;
    my $query_type;

    my $limit;
    my $limit_cgi;
    my $limit_desc;

    my $stopwords_removed;    # flag to determine if stopwords have been removed

# for handling ccl, cql, pqf queries in diagnostic mode, skip the rest of the steps
# DIAGNOSTIC ONLY!!
    if ( $query =~ /^ccl=/ ) {
        return ( undef, $', $', "q=ccl=$'", $', '', '', '', '', 'ccl' );
    }
    if ( $query =~ /^cql=/ ) {
        return ( undef, $', $', "q=cql=$'", $', '', '', '', '', 'cql' );
    }
    if ( $query =~ /^pqf=/ ) {
        return ( undef, $', $', "q=pqf=$'", $', '', '', '', '', 'pqf' );
    }

    # pass nested queries directly
    # FIXME: need better handling of some of these variables in this case
    if ( $query =~ /(\(|\))/ ) {
        return (
            undef,              $query, $simple_query, $query_cgi,
            $query,             $limit, $limit_cgi,    $limit_desc,
            $stopwords_removed, 'ccl'
        );
    }

# Form-based queries are non-nested and fixed depth, so we can easily modify the incoming
# query operands and indexes and add stemming, truncation, field weighting, etc.
# Once we do so, we'll end up with a value in $query, just like if we had an
# incoming $query from the user
    else {
        $query = ""
          ; # clear it out so we can populate properly with field-weighted, stemmed, etc. query
        my $previous_operand
          ;    # a flag used to keep track if there was a previous query
               # if there was, we can apply the current operator
               # for every operand
        for ( my $i = 0 ; $i <= @operands ; $i++ ) {

            # COMBINE OPERANDS, INDEXES AND OPERATORS
            if ( $operands[$i] ) {

              # A flag to determine whether or not to add the index to the query
                my $indexes_set;

# If the user is sophisticated enough to specify an index, turn off field weighting, stemming, and stopword handling
                if ( $operands[$i] =~ /(:|=)/ || $scan ) {
                    $weight_fields    = 0;
                    $stemming         = 0;
                    $remove_stopwords = 0;
                }
                my $operand = $operands[$i];
                my $index   = $indexes[$i];

                # Add index-specific attributes
                # Date of Publication
                if ( $index eq 'yr' ) {
                    $index .= ",st-numeric";
                    $indexes_set++;
					$stemming = $auto_truncation = $weight_fields = $fuzzy_enabled = $remove_stopwords = 0;
                }

                # Date of Acquisition
                elsif ( $index eq 'acqdate' ) {
                    $index .= ",st-date-normalized";
                    $indexes_set++;
					$stemming = $auto_truncation = $weight_fields = $fuzzy_enabled = $remove_stopwords = 0;
                }
                # ISBN,ISSN,Standard Number, don't need special treatment
                elsif ( $index eq 'nb' || $index eq 'ns' ) {
                    $indexes_set++;
                    (   
                        $stemming,      $auto_truncation,
                        $weight_fields, $fuzzy_enabled,
                        $remove_stopwords
                    ) = ( 0, 0, 0, 0, 0 );

                }
                # Set default structure attribute (word list)
                my $struct_attr;
                unless ( $indexes_set || !$index || $index =~ /(st-|phr|ext|wrdl)/ ) {
                    $struct_attr = ",wrdl";
                }

                # Some helpful index variants
                my $index_plus       = $index . $struct_attr . ":" if $index;
                my $index_plus_comma = $index . $struct_attr . "," if $index;
                if ($auto_truncation){
#					FIXME Auto Truncation is only valid for LTR languages
#					use C4::Output;
#					use C4::Languages qw(regex_lang_subtags get_bidi);
#    				$lang = $query->cookie('KohaOpacLanguage') if (defined $query && $query->cookie('KohaOpacLanguage'));
#				    my $current_lang = regex_lang_subtags($lang);
#				    my $bidi;
#				    $bidi = get_bidi($current_lang->{script}) if $current_lang->{script};
					$index_plus_comma .= "rtrn:";
				}

                # Remove Stopwords
                if ($remove_stopwords) {
                    ( $operand, $stopwords_removed ) =
                      _remove_stopwords( $operand, $index );
                    warn "OPERAND w/out STOPWORDS: >$operand<" if $DEBUG;
                    warn "REMOVED STOPWORDS: @$stopwords_removed"
                      if ( $stopwords_removed && $DEBUG );
                }

                # Detect Truncation
                my $truncated_operand;
                my( $nontruncated, $righttruncated, $lefttruncated,
                    $rightlefttruncated, $regexpr
                ) = _detect_truncation( $operand, $index );
                warn
"TRUNCATION: NON:>@$nontruncated< RIGHT:>@$righttruncated< LEFT:>@$lefttruncated< RIGHTLEFT:>@$rightlefttruncated< REGEX:>@$regexpr<"
                  if $DEBUG;

                # Apply Truncation
                if (
                    scalar(@$righttruncated) + scalar(@$lefttruncated) +
                    scalar(@$rightlefttruncated) > 0 )
                {

               # Don't field weight or add the index to the query, we do it here
                    $indexes_set = 1;
                    undef $weight_fields;
                    my $previous_truncation_operand;
                    if (scalar @$nontruncated) {
                        $truncated_operand .= "$index_plus @$nontruncated ";
                        $previous_truncation_operand = 1;
                    }
                    if (scalar @$righttruncated) {
                        $truncated_operand .= "and " if $previous_truncation_operand;
                        $truncated_operand .= $index_plus_comma . "rtrn:@$righttruncated ";
                        $previous_truncation_operand = 1;
                    }
                    if (scalar @$lefttruncated) {
                        $truncated_operand .= "and " if $previous_truncation_operand;
                        $truncated_operand .= $index_plus_comma . "ltrn:@$lefttruncated ";
                        $previous_truncation_operand = 1;
                    }
                    if (scalar @$rightlefttruncated) {
                        $truncated_operand .= "and " if $previous_truncation_operand;
                        $truncated_operand .= $index_plus_comma . "rltrn:@$rightlefttruncated ";
                        $previous_truncation_operand = 1;
                    }
                }
                $operand = $truncated_operand if $truncated_operand;
                warn "TRUNCATED OPERAND: >$truncated_operand<" if $DEBUG;

                # Handle Stemming
                my $stemmed_operand;
                $stemmed_operand = _build_stemmed_operand($operand) if $stemming;

                warn "STEMMED OPERAND: >$stemmed_operand<" if $DEBUG;

                # Handle Field Weighting
                my $weighted_operand;
                if ($weight_fields) {
                    $weighted_operand = _build_weighted_query( $operand, $stemmed_operand, $index );
                    $operand = $weighted_operand;
                    $indexes_set = 1;
                }

                warn "FIELD WEIGHTED OPERAND: >$weighted_operand<" if $DEBUG;

                # If there's a previous operand, we need to add an operator
                if ($previous_operand) {

                    # User-specified operator
                    if ( $operators[ $i - 1 ] ) {
                        $query     .= " $operators[$i-1] ";
                        $query     .= " $index_plus " unless $indexes_set;
                        $query     .= " $operand";
                        $query_cgi .= "&op=$operators[$i-1]";
                        $query_cgi .= "&idx=$index" if $index;
                        $query_cgi .= "&q=$operands[$i]" if $operands[$i];
                        $query_desc .=
                          " $operators[$i-1] $index_plus $operands[$i]";
                    }

                    # Default operator is and
                    else {
                        $query      .= " and ";
                        $query      .= "$index_plus " unless $indexes_set;
                        $query      .= "$operand";
                        $query_cgi  .= "&op=and&idx=$index" if $index;
                        $query_cgi  .= "&q=$operands[$i]" if $operands[$i];
                        $query_desc .= " and $index_plus $operands[$i]";
                    }
                }

                # There isn't a pervious operand, don't need an operator
                else {

                    # Field-weighted queries already have indexes set
                    $query .= " $index_plus " unless $indexes_set;
                    $query .= $operand;
                    $query_desc .= " $index_plus $operands[$i]";
                    $query_cgi  .= "&idx=$index" if $index;
                    $query_cgi  .= "&q=$operands[$i]" if $operands[$i];
                    $previous_operand = 1;
                }
            }    #/if $operands
        }    # /for
    }
    warn "QUERY BEFORE LIMITS: >$query<" if $DEBUG;

    # add limits
    my $group_OR_limits;
    my $availability_limit;
    foreach my $this_limit (@limits) {
        if ( $this_limit =~ /available/ ) {

# 'available' is defined as (items.onloan is NULL) and (items.itemlost = 0)
# In English:
# all records not indexed in the onloan register (zebra) and all records with a value of lost equal to 0
            $availability_limit .=
"( ( allrecords,AlwaysMatches='' not onloan,AlwaysMatches='') and (lost,st-numeric=0) )"; #or ( allrecords,AlwaysMatches='' not lost,AlwaysMatches='')) )";
            $limit_cgi  .= "&limit=available";
            $limit_desc .= "";
        }

        # group_OR_limits, prefixed by mc-
        # OR every member of the group
        elsif ( $this_limit =~ /mc/ ) {
            $group_OR_limits .= " or " if $group_OR_limits;
            $limit_desc      .= " or " if $group_OR_limits;
            $group_OR_limits .= "$this_limit";
            $limit_cgi       .= "&limit=$this_limit";
            $limit_desc      .= " $this_limit";
        }

        # Regular old limits
        else {
            $limit .= " and " if $limit || $query;
            $limit      .= "$this_limit";
            $limit_cgi  .= "&limit=$this_limit";
            if ($this_limit =~ /^branch:(.+)/) {
                my $branchcode = $1;
                my $branchname = GetBranchName($branchcode);
                if (defined $branchname) {
                    $limit_desc .= " branch:$branchname";
                } else {
                    $limit_desc .= " $this_limit";
                }
            } else {
                $limit_desc .= " $this_limit";
            }
        }
    }
    if ($group_OR_limits) {
        $limit .= " and " if ( $query || $limit );
        $limit .= "($group_OR_limits)";
    }
    if ($availability_limit) {
        $limit .= " and " if ( $query || $limit );
        $limit .= "($availability_limit)";
    }

    # Normalize the query and limit strings
    $query =~ s/:/=/g;
    $limit =~ s/:/=/g;
    for ( $query, $query_desc, $limit, $limit_desc ) {
        s/  / /g;    # remove extra spaces
        s/^ //g;     # remove any beginning spaces
        s/ $//g;     # remove any ending spaces
        s/==/=/g;    # remove double == from query
    }
    $query_cgi =~ s/^&//; # remove unnecessary & from beginning of the query cgi

    for ($query_cgi,$simple_query) {
        s/"//g;
    }
    # append the limit to the query
    $query .= " " . $limit;

    # Warnings if DEBUG
    if ($DEBUG) {
        warn "QUERY:" . $query;
        warn "QUERY CGI:" . $query_cgi;
        warn "QUERY DESC:" . $query_desc;
        warn "LIMIT:" . $limit;
        warn "LIMIT CGI:" . $limit_cgi;
        warn "LIMIT DESC:" . $limit_desc;
        warn "---------\nLeave buildQuery\n---------";
    }
    return (
        undef,              $query, $simple_query, $query_cgi,
        $query_desc,        $limit, $limit_cgi,    $limit_desc,
        $stopwords_removed, $query_type
    );
}

=head2 searchResults

Format results in a form suitable for passing to the template

=cut

# IMO this subroutine is pretty messy still -- it's responsible for
# building the HTML output for the template
sub searchResults {
    my ( $searchdesc, $hits, $results_per_page, $offset, $scan, $opac, @marcresults ) = @_;
    my $dbh = C4::Context->dbh;
    my @newresults;
    #Build branchnames hash
    #find branchname
    #get branch information.....
    my %branches;
    my $bsth =$dbh->prepare("SELECT branchcode,branchname FROM branches"); # FIXME : use C4::Branch::GetBranches
    $bsth->execute();
    while ( my $bdata = $bsth->fetchrow_hashref ) {
        $branches{ $bdata->{'branchcode'} } = $bdata->{'branchname'};
    }
# FIXME - We build an authorised values hash here, using the default framework
# though it is possible to have different authvals for different fws.

    my $shelflocations =GetKohaAuthorisedValues('items.location','',undef,$opac);

    # get notforloan authorised value list (see $shelflocations  FIXME)
    my $notforloan_authorised_value = GetAuthValCode('items.notforloan','');

    #Build itemtype hash
    #find itemtype & itemtype image
    my %itemtypes;
    $bsth =
        $dbh->prepare(
            "SELECT itemtype,description,imageurl,summary,notforloan FROM itemtypes"
        );
    $bsth->execute();
    while ( my $bdata = $bsth->fetchrow_hashref ) {
        foreach (qw(description imageurl summary notforloan)) {
            $itemtypes{ $bdata->{'itemtype'} }->{$_} = $bdata->{$_};
        }
    }

    #search item field code
    my $sth =
      $dbh->prepare(
"SELECT tagfield FROM marc_subfield_structure WHERE kohafield LIKE 'items.itemnumber'"
      );
    $sth->execute;
    my ($itemtag) = $sth->fetchrow;

    my %subfieldstosearch;
    if (!$opac || !C4::Context->preference('OPACXSLTResultsDisplay')) {
        my $sth2 = $dbh->prepare("SHOW COLUMNS FROM items");
        $sth2->execute;
        while ( ( my $column ) = $sth2->fetchrow ) {
            my ( $tagfield, $tagsubfield ) =
                &GetMarcFromKohaField( "items." . $column, "" );
            $subfieldstosearch{$column} = $tagsubfield;
        }
    }

    # handle which records to actually retrieve
    my $times;
    if ( $hits && $offset + $results_per_page <= $hits ) {
        $times = $offset + $results_per_page;
    }
    else {
        $times = $hits;	 # FIXME: if $hits is undefined, why do we want to equal it?
    }

    my $marcflavour = C4::Context->preference("marcflavour");
    # loop through all of the records we've retrieved
    for ( my $i = $offset ; $i <= $times - 1 ; $i++ ) {
        my $marcrecord;
        eval { $marcrecord = MARC::Record->new_from_xml( $marcresults[$i], 'UTF-8' )};
        if($@){
            warn "could not read marcxml. $@";
            next;
        }

        if (my $limit_to_branches = C4::XSLT::LimitItemsToTheseBranches()) {
            my @deletable_items
                = grep {!($_->subfield('a') ~~ $limit_to_branches)} $marcrecord->field($itemtag);
            $marcrecord->delete_fields(@deletable_items);
        }

        my $oldbiblio = TransformMarcToKoha( $dbh, $marcrecord, '' );
        $oldbiblio->{subtitle} = C4::Biblio::get_koha_field_from_marc('bibliosubtitle', 'subtitle', $marcrecord, '');
        $oldbiblio->{result_number} = $i + 1;

        # add imageurl to itemtype if there is one
        $oldbiblio->{imageurl} = getitemtypeimagelocation( 'opac', $itemtypes{ $oldbiblio->{itemtype} }->{imageurl} );

        if (C4::Context->preference('AuthorisedValueImages')) {
            $oldbiblio->{authorised_value_images} = C4::Items::get_authorised_value_images(
                C4::Biblio::get_biblio_authorised_values($oldbiblio->{'biblionumber'}, $marcrecord)
                );
        }
        $oldbiblio->{normalized_upc}  = GetNormalizedUPC(       $marcrecord,$marcflavour);
        $oldbiblio->{normalized_ean}  = GetNormalizedEAN(       $marcrecord,$marcflavour);
        $oldbiblio->{normalized_oclc} = GetNormalizedOCLCNumber($marcrecord,$marcflavour);
        $oldbiblio->{normalized_isbn} = GetNormalizedISBN(undef,$marcrecord,$marcflavour);
        $oldbiblio->{content_identifier_exists} = 1 if ($oldbiblio->{normalized_isbn} or $oldbiblio->{normalized_oclc} or $oldbiblio->{normalized_ean} or $oldbiblio->{normalized_upc});

        # edition information, if any
        $oldbiblio->{edition} = $oldbiblio->{editionstatement};
        $oldbiblio->{description} = $itemtypes{ $oldbiblio->{itemtype} }->{description};

        my %restype;
        my ($rescount,$reserves) = C4::Reserves::GetReservesFromBiblionumber($oldbiblio->{biblionumber});
        my $total_rescount = $rescount;
        foreach my $res (@$reserves) {
            if ($res->{itemnumber}) {
                $restype{$res->{itemnumber}} = "Attached";
                $rescount--;
            }
        }
        my ($suspended_rescount,$suspended_reserves) = C4::Reserves::GetSuspendedReservesFromBiblionumber($oldbiblio->{biblionumber});

        ($i % 2) and $oldbiblio->{'toggle'} = 1;

        # Pull out the items fields
        my @fields = $marcrecord->field($itemtag);

        # Setting item statuses for display
        my @available_items_loop;
        my @onloan_items_loop;
        my @other_items_loop;

        my $available_items;
        my $onloan_items;
        my $other_items;

        my $ordered_count         = 0;
        my $available_count       = 0;
        my $onloan_count          = 0;
        my $longoverdue_count     = 0;
        my $other_count           = 0;
        my $wthdrawn_count        = 0;
        my $itemlost_count        = 0;
        my $itemsuppress_count    = 0;
        my $itembinding_count     = 0;
        my $itemdamaged_count     = 0;
        my $item_in_transit_count = 0;
        my $item_reserve_count    = 0;
        my $can_place_holds       = 0;
        my $items_count           = scalar(@fields);
        my $other_otherstatus = '';
        my $other_otherstatus_count = 0;

        # loop through every item
        my $itemcount = 0;
        foreach my $field (@fields) {
            $itemcount++;
            my $item;

            # populate the items hash
            if (!$opac || !C4::Context->preference('OPACXSLTResultsDisplay')) {
                foreach my $code ( keys %subfieldstosearch ) {
                    $item->{$code} = $field->subfield( $subfieldstosearch{$code} );
                }
            }
            my $hbranch     = C4::Context->preference('HomeOrHoldingBranch') eq 'homebranch' ? 'homebranch'    : 'holdingbranch';
            my $otherbranch = C4::Context->preference('HomeOrHoldingBranch') eq 'homebranch' ? 'holdingbranch' : 'homebranch';
            # set item's branch name, use HomeOrHoldingBranch syspref first, fall back to the other one
            if ($item->{$hbranch}) {
                $item->{'branchname'} = $branches{$item->{$hbranch}};
            }
            elsif ($item->{$otherbranch}) {	# Last resort
                $item->{'branchname'} = $branches{$item->{$otherbranch}}; 
            }

            my $sth = $dbh->prepare(
            "SELECT description,holdsallowed
               FROM itemstatus
                 LEFT JOIN items ON itemstatus.statuscode=items.otherstatus
               WHERE itemnumber = ?"
            );
            $sth->execute($item->{itemnumber});
            my @statusvalue = $sth->fetchrow;
            my ($otherstatus,$holdsallowed,$OPACstatusdisplay);
            if (@statusvalue) {
                ($otherstatus,$holdsallowed) = @statusvalue;
                $OPACstatusdisplay = 1;
            }
            else {
                $otherstatus = '';
                $holdsallowed = 1;
                $OPACstatusdisplay = 0;
            }

            my $prefix = $item->{$hbranch} . '--' . $item->{location} . $item->{itype} . $item->{itemcallnumber};
# For each grouping of items (onloan, available, unavailable), we build a key to store relevant info about that item
            if ( $item->{onloan} ) {
                $onloan_count++;
                my $key = $prefix . $item->{onloan} . $item->{barcode};
                $onloan_items->{$key}->{due_date} = format_date($item->{onloan});
                $onloan_items->{$key}->{count}++ if $item->{$hbranch};
                $onloan_items->{$key}->{branchname} = $item->{branchname};
                $onloan_items->{$key}->{location} = $shelflocations->{ $item->{location} };
                $onloan_items->{$key}->{itemcallnumber} = $item->{itemcallnumber};
                $onloan_items->{$key}->{imageurl} = getitemtypeimagelocation( 'opac', $itemtypes{ $item->{itype} }->{imageurl} );
                # if something's checked out and lost, mark it as 'long overdue'
                if ( $item->{itemlost} ) {
                    $onloan_items->{$prefix}->{longoverdue}++;
                    $longoverdue_count++;
                } else {	# can place holds as long as item isn't lost
                    $can_place_holds = 1;
                }
            }

         # items not on loan, but still unavailable ( lost, withdrawn, damaged, suppressed )
            else {

                # item is on order
                if ( $item->{notforloan} == -1 ) {
                    $ordered_count++;
                }

                # is item in transit?
                my $transfertwhen = '';
                my ($transfertfrom, $transfertto);

                unless ($item->{wthdrawn}
                        || $item->{itemlost}
                        || $item->{damaged}
                        || $item->{suppress}
                        || $item->{notforloan}
                        || ($holdsallowed == 0)
                        || $items_count > 20) {

                    # A couple heuristics to limit how many times
                    # we query the database for item transfer information, sacrificing
                    # accuracy in some cases for speed;
                    #
                    # 1. don't query if item has one of the other statuses
                    # 2. don't check transit status if the bib has
                    #    more than 20 items
                    #
                    # FIXME: to avoid having the query the database like this, and to make
                    #        the in transit status count as unavailable for search limiting,
                    #        should map transit status to record indexed in Zebra.
                    #
                    ($transfertwhen, $transfertfrom, $transfertto) = C4::Circulation::GetTransfers($item->{itemnumber});
                }

                if ($restype{$item->{itemnumber}} ne "Attached") {
                  $restype{$item->{itemnumber}} = ($itemcount <= $rescount) ? "Reserved" : '';
                }
                # item is withdrawn, lost or damaged
                if (   $item->{wthdrawn}
                    || $item->{itemlost}
                    || $item->{damaged}
                    || $item->{suppress}
                    || ($item->{notforloan} > 0)
                    || ($holdsallowed == 0)
                    || ($transfertwhen ne '')
                    || ($restype{$item->{itemnumber}} eq "Attached")
                    || ($restype{$item->{itemnumber}} eq "Reserved") )
                {
                    $wthdrawn_count++        if $item->{wthdrawn};
                    $itemlost_count++        if $item->{itemlost};
                    $itemdamaged_count++     if $item->{damaged};
                    $item_reserve_count++    if (($restype{$item->{itemnumber}} eq "Attached") || ($restype{$item->{itemnumber}} eq "Reserved"));
                    if (($restype{$item->{itemnumber}} eq "Attached") || ($restype{$item->{itemnumber}} eq "Reserved")) {
                      $can_place_holds = 1;
                    }
                    $itemsuppress_count++    if $item->{suppress};
                    $item_in_transit_count++ if $transfertwhen ne '';
                    $item->{status} = $item->{wthdrawn} . "-" . $item->{itemlost} . "-" . $item->{damaged} . "-" . $item->{suppress} . "-" . $item->{notforloan};
                    $other_count++;
                    if ($holdsallowed == 0) {
                        $other_otherstatus_count++;
                        if ($other_otherstatus eq '') {
                            $other_otherstatus = $otherstatus;
                        }
                        else {
                            $other_otherstatus .= ', ' . $otherstatus;
                        }
                    }

                    my $key = $prefix . $item->{status};
                    foreach (qw(wthdrawn itemlost damaged suppress branchname itemcallnumber)) {
                    	$other_items->{$key}->{$_} = $item->{$_};
                    }
                    $other_items->{$key}->{intransit} = ($transfertwhen ne '') ? 1 : 0;
                    $other_items->{$key}->{reserved} = (($restype{$item->{itemnumber}} eq "Attached") || ($restype{$item->{itemnumber}} eq "Reserved")) ? 1 : 0;
                    $other_items->{$key}->{notforloan} = GetAuthorisedValueDesc('','',$item->{notforloan},'','',$notforloan_authorised_value,$opac) if $notforloan_authorised_value;
                    $other_items->{$key}->{count}++ if $item->{$hbranch};
                    $other_items->{$key}->{location} = $shelflocations->{ $item->{location} };
                    $other_items->{$key}->{imageurl} = getitemtypeimagelocation( 'opac', $itemtypes{ $item->{itype} }->{imageurl} );
                    $other_items->{$key}->{OPACstatusdisplay} = $OPACstatusdisplay;
                    if (!defined($other_items->{$key}->{otherstatus})) {
                        $other_items->{$key}->{otherstatus} = $otherstatus;
                    }
                    else {
                        $other_items->{$key}->{otherstatus} .=', ' . $otherstatus;
                    }
                }
                # item is available
                else {
                    $can_place_holds = 1;
                    $available_count++;
                    $available_items->{$prefix}->{count}++ if $item->{$hbranch};
                    foreach (qw(branchname itemcallnumber)) {
                    	$available_items->{$prefix}->{$_} = $item->{$_};
                    }
                    $available_items->{$prefix}->{location} = $shelflocations->{ $item->{location} };
                    $available_items->{$prefix}->{imageurl} = getitemtypeimagelocation( 'opac', $itemtypes{ $item->{itype} }->{imageurl} );
                    $available_items->{$prefix}->{OPACstatusdisplay} = $OPACstatusdisplay;
                    $available_items->{$prefix}->{otherstatus} = $otherstatus;
                }
            }
        }    # notforloan, item level and biblioitem level
        my ($availableitemscount, $onloanitemscount, $otheritemscount) = (0, 0, 0);
        my $maxitems = C4::Context->preference('maxItemsinSearchResults') // 1;
        for my $key ( sort keys %$onloan_items ) {
            ($onloanitemscount++ > $maxitems) and last;
            push @onloan_items_loop, $onloan_items->{$key};
        }
        for my $key ( sort keys %$other_items ) {
            ($otheritemscount++ > $maxitems) and last;
            push @other_items_loop, $other_items->{$key};
        }
        for my $key ( sort keys %$available_items ) {
            ($availableitemscount++ > $maxitems) and last;
            push @available_items_loop, $available_items->{$key}
        }

        # XSLT processing of some stuff for staff client
        if (C4::Context->preference("XSLTResultsDisplay") && !$scan && (!$opac)) {
            $oldbiblio->{XSLTResultsRecord} = XSLTParse4Display(
                $oldbiblio->{biblionumber}, $marcrecord, 'Results', 'intranet');
        }
        # XSLT processing of some stuff for OPAC
        if (C4::Context->preference("OPACXSLTResultsDisplay") && !$scan && ($opac)) {
            $oldbiblio->{XSLTResultsRecord} = XSLTParse4Display(
                $oldbiblio->{biblionumber}, $marcrecord, 'Results', 'opac');
        }

        # last check for norequest : if itemtype is notforloan, it can't be reserved either, whatever the items
        $can_place_holds = 0
            if $itemtypes{ $oldbiblio->{itemtype} }->{notforloan};
        $oldbiblio->{norequests} = 1 unless $can_place_holds;
        $oldbiblio->{itemsplural}          = 1 if $items_count > 1;
        $oldbiblio->{items_count}          = $items_count;
        $oldbiblio->{available_items_loop} = \@available_items_loop;
        $oldbiblio->{onloan_items_loop}    = \@onloan_items_loop;
        $oldbiblio->{other_items_loop}     = \@other_items_loop;
        $oldbiblio->{availablecount}       = $available_count;
        $oldbiblio->{availableplural}      = 1 if $available_count > 1;
        $oldbiblio->{onloancount}          = $onloan_count;
        $oldbiblio->{onloanplural}         = 1 if $onloan_count > 1;
        $oldbiblio->{othercount}           = $other_count;
        $oldbiblio->{otherplural}          = 1 if $other_count > 1;
        $oldbiblio->{wthdrawncount}        = $wthdrawn_count;
        $oldbiblio->{itemlostcount}        = $itemlost_count;
        $oldbiblio->{damagedcount}         = $itemdamaged_count;
        $oldbiblio->{intransitcount}       = $item_in_transit_count;
        $oldbiblio->{orderedcount}         = $ordered_count;
        $oldbiblio->{reservecount}         = $item_reserve_count;
        $oldbiblio->{total_reservecount}   = $total_rescount;
        $oldbiblio->{active_reservecount}  = $total_rescount - $suspended_rescount;
        $oldbiblio->{other_otherstatus}    = $other_otherstatus;
        $oldbiblio->{other_otherstatuscount} = $other_otherstatus_count;
        push( @newresults, $oldbiblio );
    }
    return @newresults;
}

=head2 enabled_staff_search_views

%hash = enabled_staff_search_views()

This function returns a hash that contains three flags obtained from the system
preferences, used to determine whether a particular staff search results view
is enabled.

=over 2

=item C<Output arg:>

    * $hash{can_view_MARC} is true only if the MARC view is enabled
    * $hash{can_view_ISBD} is true only if the ISBD view is enabled
    * $hash{can_view_labeledMARC} is true only if the Labeled MARC view is enabled

=item C<usage in the script:>

=back

$template->param ( C4::Search::enabled_staff_search_views );

=cut

sub enabled_staff_search_views
{
	return (
		can_view_MARC			=> C4::Context->preference('viewMARC'),			# 1 if the staff search allows the MARC view
		can_view_ISBD			=> C4::Context->preference('viewISBD'),			# 1 if the staff search allows the ISBD view
		can_view_labeledMARC	=> C4::Context->preference('viewLabeledMARC'),	# 1 if the staff search allows the Labeled MARC view
	);
}


=head2 z3950_search_args

$arrayref = z3950_search_args($matchpoints)

This function returns an array reference that contains the search parameters to be
passed to the Z39.50 search script (z3950_search.pl). The array elements
are hash refs whose keys are name, value and encvalue, and whose values are the
name of a search parameter, the value of that search parameter and the URL encoded
value of that parameter.

The search parameter names are lccn, isbn, issn, title, author, dewey and subject.

The search parameter values are obtained from the bibliographic record whose
data is in a hash reference in $matchpoints, as returned by Biblio::GetBiblioData().

If $matchpoints is a scalar, it is assumed to be an unnamed query descriptor, e.g.
a general purpose search argument. In this case, the returned array contains only
entry: the key is 'title' and the value and encvalue are derived from $matchpoints.

If a search parameter value is undefined or empty, it is not included in the returned
array.

The returned array reference may be passed directly to the template parameters.

=over 2

=item C<Output arg:>

    * $array containing hash refs as described above

=item C<usage in the script:>

=back

$data = Biblio::GetBiblioData($bibno);
$template->param ( MYLOOP => C4::Search::z3950_search_args($data) )

*OR*

$template->param ( MYLOOP => C4::Search::z3950_search_args($searchscalar) )

=cut

sub z3950_search_args {
    my $bibrec = shift;
    $bibrec = { title => $bibrec } if !ref $bibrec;
    my $array = [];
    for my $field (qw/ lccn isbn issn title author dewey subject /)
    {
        my $encvalue = URI::Escape::uri_escape_utf8($bibrec->{$field});
        push @$array, { name=>$field, value=>$bibrec->{$field}, encvalue=>$encvalue } if defined $bibrec->{$field};
    }
    return $array;
}


END { }    # module clean-up code here (global destructor)

1;
__END__

=head1 AUTHOR

Koha Developement team <info@koha.org>

=cut