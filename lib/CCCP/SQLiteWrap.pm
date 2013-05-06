package CCCP::SQLiteWrap;
use strict;
use warnings;

our $VERSION = '0.021';

use Carp;
use DBI;
use File::Copy;
use Data::UUID;
use Digest::MD5 qw(md5_hex);
    
    $CCCP::SQLiteWrap::OnlyPrint = 0;

    my $t_create_pattern = 'CREATE TABLE IF NOT EXISTS %s (%s)';
    my $i_create_pattern = 'CREATE INDEX %s ON %s(%s)';
    my $tr_create_pattern = ['DROP TRIGGER IF EXISTS %s','CREATE TRIGGER IF NOT EXISTS %s %s %s ON %s FOR EACH ROW BEGIN %s; END;'];

sub connect {
    my ($class, $path, $redump) = @_;
    my $self = ref $class ? $class : bless({ db => undef, path => $path, need_redump => $redump }, $class);
    $self->{db} = DBI->connect('dbi:SQLite:dbname='.$self->path, '', '',{RaiseError => 1, InactiveDestroy => 1});
    croak $DBI::errstr if $DBI::errstr;
    $self->check;
    return $self;
}

sub db     {$_[0]->{db}}
sub path   {$_[0]->{path}}
sub need_redump {$_[0]->{need_redump}}

sub check {
    my $self = shift;

    unless ($self->db->ping()) {
        croak "Can't ping SQLite base by path ".$self->path;
    };
    
    my $need_rebackup = 0;
    my @table = $self->show_tables;
    for my $table (@table) {
        next unless $table;
        eval{
            $self->db->selectall_arrayref("SELECT * FROM $table LIMIT 1")
        };
        if ($@ or $DBI::errstr) {
            $need_rebackup++;
            last;
        };
    };
    if ($need_rebackup) {
        if ($self->need_redump) {
	        carp "SQLite base ".$self->path." was return error like 'database disk image is malformed' and need redump";
            unless ($self->redump) {
	            croak "Redump failed";
            } else {
                return 1;
            }
        } else {
            croak "SQLite base ".$self->path." was return error like 'database disk image is malformed' and need redump";
        }
    };
    
    return 1;    
}

sub select2arhash {
    my $self = shift;
    my $query = shift;
    my $sth = $self->db->prepare($query);
    $sth->execute(@_);
    return $sth->fetchall_arrayref({});
}

sub create_table {
    my $self = shift;
    unless (@_ % 2 == 0) {
        carp "Incorrect call create_table";
        return;
    }
    my %desc = @_;
    
    my $exisis_table = $self->show_tables;
    my $can_fk = $self->db->selectrow_arrayref('PRAGMA foreign_keys');
    
    my @new_table = ();
    my @create_table = ();
    
    while (my ($name, $param) = each %desc) {
        next if (
            not $name
            or $exisis_table->{$name}++ 
            or ref $param ne 'HASH' 
            or not exists $param->{fields}
        ); 
        
        my $desc = ''; my @index = ();
        if (exists $param->{meta}) {
            
            # set default value
            my %default = %{ $param->{meta}->{default} || {} }; 
            while (my ($field, $defval) = each %default) {
                $param->{fields}->{$field} .= ' DEFAULT '.$self->db->quote($defval) if exists $param->{fields}->{$field};
            }
            
            # set not null
            for ( @{$param->{meta}->{not_null} || []} ) {
                $param->{fields}->{$_} .= ' NOT NULL' if exists $param->{fields}->{$_};
            }
            
            # set unique
            for ( @{$param->{meta}->{unique} || []} ) {
                $param->{fields}->{$_} .= ' UNIQUE' if exists $param->{fields}->{$_};
            }

            # set primary key
            if (exists $param->{meta}->{pk}) {
                $param->{fields}->{'PRIMARY KEY'} = "(".join(', ',map {$self->db->quote($_)} @{$param->{meta}->{pk}}).")";
            };
            
            # set fk
            if ($can_fk and exists $param->{meta}->{fk}) {
                unless ($can_fk->[0]) {
                    $self->db->do('PRAGMA foreign_keys = ON');
                    $can_fk->[0] = 1;
                };
                my %fk = %{$param->{meta}->{fk}};
                while (my ($fk_field,$fk_param) = each %fk) {
                    # REFERENCES artist(artistid) ON DELETE SET DEFAULT
                    next if (not $fk_field or ref $fk_field or ref $fk_param ne 'HASH' or not exists $param->{fields}->{$fk_field});
                    $param->{fields}->{$fk_field} .= sprintf(' REFERENCES %s(%s)',$fk_param->{table},$fk_param->{field});
                    $param->{fields}->{$fk_field} .= ' ON UPDATE '.$fk_param->{on_update} if exists $fk_param->{on_update};
                    $param->{fields}->{$fk_field} .= ' ON DELETE '.$fk_param->{on_delete} if exists $fk_param->{on_delete};
                };
            };
            
            # set index
            if (exists $param->{meta}->{index}) {
                my $index = {};
                @index = grep {$_} map {                    
                    my $ind_md5 = md5_hex(join ',',sort {$a cmp $b} @$_);
                    $index->{$ind_md5}++ ? 
                        undef :
                        sprintf(
                           $i_create_pattern,
                           sprintf('_%s', Data::UUID->new()->create_hex()),
                           $name,
                           join(',', map {$self->db->quote($_)} @$_)
                        );
                } @{$param->{meta}->{index}};                
            };
            
        };
        
        my $create_table = sprintf(
            $t_create_pattern,
            $name,
            join(',',
                grep {$_}
                map {
                    exists $param->{fields}->{$_} ?
                    join(' ',$_ eq 'PRIMARY KEY' ? $_ : $self->db->quote($_),$param->{fields}->{$_}) :
                    undef
                } ((grep {! /^PRIMARY KEY$/ } keys %{$param->{fields}}), 'PRIMARY KEY')
            )
        );
        
        if ($CCCP::SQLiteWrap::OnlyPrint) {
            print join("\n", $create_table, @index);
            print "\n------------------------------\n";
        } else {
            $self->do_transaction($create_table,@index)
        };
        push @new_table, $name;
    }
    
    return wantarray ? @new_table : scalar @new_table;
}

sub do_transaction {
    my $self = shift;
    my @query = @_;
    return unless @query;     
    $self->db->begin_work or croak $self->db->errstr;
    $self->db->do($_) for @query;
    $self->db->commit;
    return;
}

sub show_tables {
    my $self = shift;
    
    my @tables = grep { ! /^sqlite_/ } map { s/"//g; $_ } $self->db->tables;
    
    if (wantarray) {
        return @tables;
    } else {
	    my %ret = ();
        @ret{@tables} = (1) x @tables;
        return \%ret;
    }
}

sub close {
    my $self = shift;
    $self->db->disconnect;
}

sub redump {
    my $self = shift;
    $self->close();
    if (-e $self->path and -s _) {
        my $tmp_file = $self->path.'.bak';
        my $i = 0;
        while (-e $tmp_file and $i < 3) {
            $tmp_file .= '.bak';
            $i++;
        }
        die "can't create temp file, $tmp_file already exists" if $i == 3;
        my $dump_command = sprintf 'sqlite3 %s ".dump" | sqlite3  %s', $self->path, $tmp_file;
        system $dump_command;
        move($tmp_file, $self->path);        
    } else {
        unlink $self->path;
        my $create_command = sprintf 'sqlite3 %s "select 1"', $self->path;
        system $create_command;
    };
    return $self->connect();
}

# $self->add_index('tablename' => [asfd,asfds,sdf], 'safasf' => [asfdsf,asfd])
sub add_index {
    my $self = shift;
    my %indexes = @_;
    
    my $exisis_table = $self->show_tables;
    my $ret = 0;
    
    # check exists index
    while (my ($table, $ind_array) = each %indexes) {
        next if (not $table or not exists $exisis_table->{$table} or not $ind_array);
        my @index = ();
        my $exists_index = {};
        my $index_name = $self->db->selectall_arrayref('PRAGMA index_list('.$self->db->quote($table).')');
        next unless $index_name;
        for (@$index_name) {
            my $i_name = $_->[1];
            my $index_fields = $self->db->selectrow_arrayref('PRAGMA index_info('.$self->db->quote($i_name).')');
            $exists_index->{md5_hex(join(',',sort {$a cmp $b} @$index_fields))}++ if $index_fields;         
        }

        # create new index sql
        foreach my $new_index_fields (@$ind_array) {
            next if (not $new_index_fields or ref $new_index_fields ne 'ARRAY');
            next if $exists_index->{md5_hex(join(',',sort {$a cmp $b} @$new_index_fields))}++;
            my $unic_name = sprintf('_%s',Data::UUID->new()->create_hex());
            push @index, sprintf(
                            $i_create_pattern,
                            $unic_name,
                            $table,
                            join(',',map {$self->db->quote($_)} @$new_index_fields)
            );
            $ret++;
        };
        
        # create new index in base
        if ($CCCP::SQLiteWrap::OnlyPrint) {
            print join("\n", @index);
            print "\n------------------------------\n";
        } else {
            $self->do_transaction(@index);
        };      
    };
    
    return $ret;
}

sub table_exists {
    my ($self,$table) = @_;
    return 0 unless $table;
    return (grep { /^\Q$table\E$/i } map { s/"//g; $_ } $self->db->tables) ? 1 : 0; 
}

# $self->index_exists('name' => ['field1','field2']);
# it'll return name of index if this one exists
sub index_exists {
    my ($self,$table,$ind_fields) = @_;    
    return unless ($table and $ind_fields and ref $ind_fields eq 'ARRAY' and $self->table_exists($table));  

    my $index_name = $self->db->selectall_arrayref('PRAGMA index_list('.$self->db->quote($table).')');
    return unless $index_name;
    
    my $exists_index = {};
    for (@$index_name) {
        my $i_name = $_->[1];
        my $index_fields = $self->db->selectall_arrayref('PRAGMA index_info('.$self->db->quote($i_name).')');
        if ($index_fields) {
            $index_fields = [map {$_->[2]} @$index_fields];
            $exists_index->{md5_hex(join(',',sort {$a cmp $b} @$index_fields))} = $i_name;         
        };
    } 
    
    my $ind_fields_md5 = md5_hex(join(',',sort {$a cmp $b} @$ind_fields));
    
    return exists $exists_index->{$ind_fields_md5} ? $exists_index->{$ind_fields_md5} : 0;
}

sub create_trigger {
    my $self = shift;
    my %triggers = @_;
    
    my @transaction_query = ();
    
    my $exisis_table = $self->show_tables;
    while (my ($t_name, $param) = each %triggers) {  
       next if (not $t_name or not exists $exisis_table->{$t_name} or ref $param ne 'HASH' or not keys %$param);
       while (my ($t_event_1, $event_param) = each %$param) {
            next if (not $t_event_1 or ref $event_param ne 'HASH' or not keys %$event_param);
            while (my ($t_event_2, $sql) = each %$event_param) {
                next unless ($t_event_2 and ref $sql eq 'ARRAY' and @$sql);
                $sql = [map {s/;\s*$//s; $_} @$sql];
                my $tr_name = join('_', map {lc $_} ('trigger', $t_name, $t_event_1, $t_event_2, md5_hex(lc(join('',@$sql)))));
                # delete trigger
                push @transaction_query, sprintf(
                    $tr_create_pattern->[0],
                    $tr_name
                );
                # create trigger
                push @transaction_query, sprintf(
                    $tr_create_pattern->[1],                                
                    $tr_name,
                    uc($t_event_1),
                    uc($t_event_2),
                    $t_name,
                    join(';',@$sql)
                );
            };
       };
    };
    
    # create transaction in base
    if ($CCCP::SQLiteWrap::OnlyPrint) {
            print join("\n",@transaction_query);
            print "\n------------------------------\n";
    } else {
            $self->do_transaction(@transaction_query);
    };
    return;   
}


1;
__END__
