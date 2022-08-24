# relay for multirpg

package relay;
use strict;
use warnings;
use base 'ZNC::Module';
use Data::Dumper;
use JSON;

sub description  { "Perl module to relay chat channels across networks." }
sub module_types { $ZNC::CModInfo::GlobalModule }

sub OnLoad {
    my ($self, $args, $message) = @_;
    # PutStatus/PutModule don't work, as this just reloaded,
    # and network/modnick aren't populated or something
    $self->load_config();
    return $ZNC::CONTINUE;
}

sub load_config {
    my $self = shift;
    eval {
        if ($self->ExistsNV('config')) {
            $self->{config} = decode_json $self->GetNV('config');
            $self->PutModule("Config loaded.");
            $self->PutModule($self->{config});
        } else {
            $self->PutModule("Config failed to load; Creating blank config.");
            $self->new_config();
        }
    };
    if ($@) {
        $self->PutModule($@);
    }
    return 1;
}

sub new_config {
    # Create a new, blank config
    my $self = shift;
    $self->{config} = decode_json("{}");
    $self->save_config();
    return $self->{config};
}

sub save_config {
    my $self = shift;
    $self->SetNV('config', encode_json $self->{config});
    $self->PutModule("Config saved.");
    return 1;
}

sub OnChanMsg {
    my ($self, $Nick, $Channel, $msg) = @_;
    my $nick = $Nick->GetNick();
    my $chan = lc($Channel->GetName());
    my $net = $self->GetNetwork()->GetName();
    #$self->PutModule("Nick($nick) Msg($msg) Chan($chan) Net($net)");
    if (exists $self->{config}{$net}{$chan}) {
        my $key = $self->{config}{$net}{$chan};
        #$self->PutModule("need to share a line for key '$key'");
        my @netchans = $self->get_netchans_from_key($key);
        if (@netchans) {
            my $newmsg = "\002[$net]\002 <$nick> $msg";
            #$self->PutModule("formatted message: '$newmsg'");
            #$self->PutModule("Netchans: " . Dumper(\@netchans));
            foreach my $netchan (@netchans) {
                my ($newnet, $newchan) = @$netchan;
                next if $newnet eq $net and $newchan eq $chan;
                #$self->PutModule("need to share a line from $net:$chan to $newnet:$newchan");
                my $netobj = $self->get_netobj_by_netname($newnet);
                $netobj->PutIRC("PRIVMSG $newchan :$newmsg") if $netobj;
            }
        }
    }
    return $ZNC::CONTINUE;
}

sub OnChanAction {
    my ($self, $Nick, $Channel, $msg) = @_;
    my $nick = $Nick->GetNick();
    my $chan = lc($Channel->GetName());
    my $net = $self->GetNetwork()->GetName();
    #$self->PutModule("Nick($nick) Msg($msg) Chan($chan) Net($net)");
    if (exists $self->{config}{$net}{$chan}) {
        my $key = $self->{config}{$net}{$chan};
        #$self->PutModule("need to share a line for key '$key'");
        my @netchans = $self->get_netchans_from_key($key);
        if (@netchans) {
            my $newmsg = "\002[$net]\002 * $nick $msg";
            #$self->PutModule("formatted message: '$newmsg'");
            #$self->PutModule("Netchans: " . Dumper(\@netchans));
            foreach my $netchan (@netchans) {
                my ($newnet, $newchan) = @$netchan;
                next if $newnet eq $net and $newchan eq $chan;
                #$self->PutModule("need to share a line from $net:$chan to $newnet:$newchan");
                my $netobj = $self->get_netobj_by_netname($newnet);
                $netobj->PutIRC("PRIVMSG $newchan :$newmsg") if $netobj;
            }
        }
    }
    return $ZNC::CONTINUE;
}

#sub OnStatusCommand {
#    my ($self, $command) = (shift, shift);
#    my $network = $self->GetNetwork()->GetName();
#    $self->PutModule("OnStatusCommand ($network): $command");
#    return $ZNC::CONTINUE;
#}

sub OnModCommand {
    my ($self, $line) = @_;
    $self->PutModule("OnModCommand: $line");
    my ($cmd, $args) = ($line =~ /^(\S+)\s?(.*)?$/);
    $self->PutModule("cmd($cmd) args($args)");
    if ($cmd eq 'status') {
        $self->do_status();
    } elsif ($cmd eq 'add' || $cmd eq 'addkey') {
        $self->add_key($args);
    } elsif ($cmd eq 'del' || $cmd eq 'delkey') {
        $self->del_key($args);
    } elsif ($cmd eq 'loadconfig') {
        $self->load_config();
    } elsif ($cmd eq 'saveconfig') {
        $self->save_config();
    } elsif ($cmd eq 'newconfig') {
        $self->{config} = $self->new_config();
    }
    return $ZNC::CONTINUE;
}

sub do_status {
    my $self = shift;
    eval {
        my $tbl = ZNC::CTable->new();
        #$self->PutModule("Config: " . Dumper($self->{config}));
        $tbl->AddColumn("Network");
        $tbl->AddColumn("Channels");
        $tbl->AddColumn("Key");
        eval {
            foreach my $net (sort keys %{ $self->{config} }) {
                foreach my $chan (sort keys %{ $self->{config}{$net} }) {
                    my $key = $self->{config}{$net}{$chan};
                    $tbl->AddRow();
                    $tbl->SetCell("Network", $net);
                    $tbl->SetCell("Channels", $chan);
                    $tbl->SetCell("Key", $key);
                }
            }
        };
        if ($@) {
            $tbl->SetCell("Channels", $@);
            $self->PutModule("Woopsie: $@");
        }
        $self->PutModule($tbl);
    };
    if ($@) {
        $self->PutModule("Woopsie: $@");
    }
    return $ZNC::Continue;
}

sub add_key {
    my ($self, $line) = @_;
    eval {
        my @opts = split(' ', $line);
        $self->PutModule("Opts: " . join(', ', @opts));
        $self->PutModule("length: " . scalar(@opts));
        if (scalar(@opts) != 3) {
            $self->PutModule("Syntax:  add <network> <channel> <key>");
            return $ZNC::CONTINUE;
        }
        my ($network, $channel, $key) = @opts;
        $network = lc($network);
        $channel = lc($channel);
        my $nets = $self->GetUser()->GetNetworks();
        my $realnet;
        foreach my $net (@$nets) {
            my $netname = $net->GetName();
            if (lc($netname) eq $network) {
                $realnet = $netname;
                last;
            }
        }
        if (!defined $realnet) {
            $self->PutModule("'$network' is not a valid network.");
            $self->PutModule("Valid networks: " . join(', ', @$nets));
            return $ZNC::CONTINUE;
        }
        $self->PutModule("Adding network($realnet) channel($channel) key($key)");
        $self->{config}{$realnet}{$channel} = $key;
        $self->save_config();
        return $ZNC::CONTINUE;
    };
    if ($@) {
        $self->PutModule("Woopsie: $@");
    }
}

sub del_key {
    my ($self, $args) = @_;
    my ($net, $chan) = split(' ', $args);
    if (!defined $net || !defined $chan) {
        $self->PutModule("Syntax:  delkey <network> <channel>");
        return $ZNC::CONTINUE;
    }
    $chan = lc($chan);
    $self->PutModule("Deleting key from '$net'--> '$chan' ...");
    if (!exists $self->{config}{$net}) {
        $self->PutModule("You don't have any settings for network '$net'. (Network names are case-sensitive)");
        return $ZNC::CONTINUE;
    }
    if (!exists $self->{config}{$net}{$chan}) {
        $self->PutModule("You don't have a key set for channel '$chan' on network '$net'.");
        return $ZNC::CONTINUE;
    }
    my $key = delete $self->{config}{$net}{$chan};
    $self->save_config();
    $self->PutModule("Removed key '$key' from channel $chan on network $net.");
    return $ZNC::CONTINUE;
}

sub get_netchans_from_key {
    my ($self, $key) = @_;
    my @netchans;
    foreach my $net (keys %{ $self->{config} }) {
        foreach my $chan (keys %{ $self->{config}{$net} }) {
            if ($self->{config}{$net}{$chan} eq $key) {
                push @netchans, [$net, $chan];
            }
        }
    }
    return @netchans;
}

sub get_netobj_by_netname {
    my ($self, $netname) = @_;
    my $nets = $self->GetUser()->GetNetworks();
    foreach my $net (@$nets) {
        if (lc($netname) eq lc($net->GetName())) {
            return $net;
        }
    }
    return undef;
}

1;

