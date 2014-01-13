#!/usr/bin/env perl
#
# Copyright (c) 2014 OpenDNSSEC AB (svb). All rights reserved.

use common::sense;
use Carp;

use EV ();
use AnyEvent ();
use AnyEvent::HTTP ();

use Pod::Usage ();
use Getopt::Long ();
use Log::Log4perl ();
use XML::LibXML ();
use JSON::XS ();
use POSIX;
use YAML ();

my $help = 0;
my $log4perl;
my $daemon = 0;
my $pidfile;
my $config;

my %CFG = (
    CHECK_PULL_REQUESTS_INTERVAL => 300,
    CHECK_PULL_REQUEST_INTERVAL => 600,
    REVIEWER => {
    },
    
    # GITHUB_USERNAME
    # GITHUB_TOKEN
    GITHUB_REPO => {
        # repo =>
        #   jobs =>
    },

    # JENKINS_USERNAME
    # JENKINS_TOKEN
    JENKINS_JOBS => {
        # job =>
        #   pull-* =>
    },
    
    OPERATION_START => '06:00',
    OPERATION_END => '21:00'
);

my $JSON = JSON::XS->new;
my @watchers;
my %pull_request;

Getopt::Long::GetOptions(
    'help|?' => \$help,
    'log4perl:s' => \$log4perl,
    'daemon' => \$daemon,
    'pidfile:s' => \$pidfile,
    'config=s' => \$config
) or Pod::Usage::pod2usage(2);
Pod::Usage::pod2usage(1) if $help;

{
    my $CFG;
    eval {
        $CFG = YAML::LoadFile($config);
    };
    if ($@ or !defined $CFG or ref($CFG) ne 'HASH') {
        confess 'Unable to load config file ', $config, ': ', $@;
    }
    %CFG = ( %CFG, %$CFG );
}

if (defined $log4perl and -f $log4perl) {
    Log::Log4perl->init($log4perl);
}
elsif ($daemon) {
    Log::Log4perl->init( \q(
    log4perl.logger                    = DEBUG, SYSLOG
    log4perl.appender.SYSLOG           = Log::Dispatch::Syslog
    log4perl.appender.SYSLOG.min_level = debug
    log4perl.appender.SYSLOG.ident     = exec
    log4perl.appender.SYSLOG.facility  = daemon
    log4perl.appender.SYSLOG.layout    = Log::Log4perl::Layout::SimpleLayout
    ) );
}
else {
    Log::Log4perl->init( \q(
    log4perl.logger                   = DEBUG, Screen
    log4perl.appender.Screen          = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr   = 0
    log4perl.appender.Screen.layout   = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.layout.ConversionPattern = %d %F [%L] %p: %m%n
    ) );
}

if ($daemon) {
    unless (POSIX::setsid) {
        print STDERR 'Unable to create a new process session (setsid): ', $!, "\n";
        exit(2);
    }

    my $pid = fork();
    if ($pid < 0) {
        print STDERR 'Unable to fork a new process: ', $!, "\n";
        exit(2);
    }
    elsif ($pid) {
        exit 0;
    }
    
    if ($pidfile) {
        unless(open(PIDFILE, '>', $pidfile,)) {
            print STDERR 'Unable to open pidfile "', $pidfile, '" for writing: ', $!, "\n";
            exit(2);
        }
        print PIDFILE POSIX::getpid, "\n";
        close(PIDFILE);
        
        unless(open(PIDFILE, $pidfile)) {
            print STDERR 'Unable to open pidfile "', $pidfile, '" for verifying pid: ', $!, "\n";
            exit(2);
        }
        my $pidinfile = <PIDFILE>;
        chomp($pidinfile);
        close(PIDFILE);
        
        unless (POSIX::getpid == $pidinfile) {
            print STDERR 'Unable to correctly write my pid to pidfile "', $pidfile, "\"\n";
            exit(2);
        }
    }

    unless (chdir('/')) {
        print STDERR 'Unable to chdir to / : ', $!;
        exit(2);
    }
    POSIX::setsid();
    umask(0);
    foreach (0 .. (POSIX::sysconf (&POSIX::_SC_OPEN_MAX) || 1024)) {
        POSIX::close($_);
    }

    open(STDIN, '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
}

my $cv = AnyEvent->condvar;

push(@watchers,
    AnyEvent->signal(signal => "HUP", cb => sub {
    }),
    AnyEvent->signal(signal => "PIPE", cb => sub {
    }),
    AnyEvent->signal(signal => "INT", cb => sub {
        unless ($daemon) {
            $cv->send;
        }
    }),
    AnyEvent->signal(signal => "QUIT", cb => sub {
        $cv->send;
    }),
    AnyEvent->signal(signal => "TERM", cb => sub {
        $cv->send;
    }),
);

my $logger = Log::Log4perl->get_logger;
$logger->info($0, ' starting');

foreach my $repo (qw(SoftHSMv1 opendnssec-workflow-test)) {
    my $lock = 0;
    push(@watchers, AnyEvent->timer(
        after => 1,
        interval => $CFG{CHECK_PULL_REQUESTS_INTERVAL},
        cb => sub {
            if ($lock) {
                $logger->info('CheckPullRequests ', $repo, ' locked?');
                return;
            }
            unless (isWithinOperationHours()) {
                return;
            }
            
            $lock = 1;
            $logger->info('CheckPullRequests ', $repo, ' start');
            undef($@);
            CheckPullRequests($repo, sub {
                if ($@) {
                    $logger->error('CheckPullRequests ', $repo, ' ', $@);
                    undef($@);
                }
                else {
                    $logger->info('CheckPullRequests ', $repo, ' finish');
                }
                $lock = 0;
            });
        }
    ));
}

$cv->recv;
$logger->info($0, ' stopping');
@watchers = ();
%pull_request = ();
exit(0);

sub isWithinOperationHours {
    my $now = strftime('%H:%M', gmtime);
    
    if ($now ge $CFG{OPERATION_START} and $now lt $CFG{OPERATION_END}) {
        return 1;
    }
    
    return;
}

sub GitHubRequest {
    my $url = shift;
    my $cb = shift;
    my %args = ( @_ );
    
    $url =~ s/^https:\/\/api.github.com\///o;
    $args{headers}->{Accept} = 'application/vnd.github.v3';
    
    $logger->debug('GitHubRequest ', 'https://'.$CFG{GITHUB_USERNAME}.':'.$CFG{GITHUB_TOKEN}.'@api.github.com/'.$url);
    
    AnyEvent::HTTP::http_get 'https://'.$CFG{GITHUB_USERNAME}.':'.$CFG{GITHUB_TOKEN}.'@api.github.com/'.$url,
        %args,
        sub {
            my ($body, $header) = @_;
            
            unless (ref($header) eq 'HASH') {
                $@ = '$header is not hash ref';
                $cb->();
                return;
            }
            
            unless ($header->{Status} eq '200') {
                unless ($@) {
                    $@ = $header->{Reason};
                }
                
                $cb->();
                return;
            }
            
            eval {
                $body = $JSON->decode($body);
            };
            if ($@) {
                $logger->error($@);
                $cb->();
            }
            else {
                $cb->($body);
            }
        };
}

sub VerifyPullRequest {
    my ($pull) = @_;
    
    unless (ref($pull) eq 'HASH'
        and defined $pull->{number}
        and defined $pull->{patch_url}
        and exists $pull->{merged_at}
        and ref($pull->{_links}) eq 'HASH'
        and ref($pull->{_links}->{comments}) eq 'HASH'
        and defined $pull->{_links}->{comments}->{href}
        and ref($pull->{_links}->{statuses}) eq 'HASH'
        and defined $pull->{_links}->{statuses}->{href})
    {
        return;
    }
    
    return 1;
}

sub VerifyReviewComment {
    my ($comment) = @_;
    
    unless (ref($comment) eq 'HASH'
        and defined $comment->{created_at}
        and defined $comment->{body}
        and ref($comment->{user}) eq 'HASH'
        and defined $comment->{user}->{login})
    {
        return;
    }
    
    return 1;
}

sub VerifyStatus {
    my ($status) = @_;
    
    unless (ref($status) eq 'HASH'
        and defined $status->{created_at}
        and defined $status->{state}
        and defined $status->{description}
        and ref($status->{creator}) eq 'HASH'
        and defined $status->{creator}->{login})
    {
        return;
    }
    
    return 1;
}

sub JenkinsRequest {
    my $url = shift;
    my $cb = shift;
    my %args = ( @_ );
    
    $url =~ s/^https:\/\/jenkins.opendnssec.org\///o;
    
    $logger->debug('JenkinsRequest ', 'https://'.$CFG{JENKINS_USERNAME}.':'.$CFG{JENKINS_TOKEN}.'@jenkins.opendnssec.org/'.$url.'/api/json');

    AnyEvent::HTTP::http_get 'https://'.$CFG{JENKINS_USERNAME}.':'.$CFG{JENKINS_TOKEN}.'@jenkins.opendnssec.org/'.$url.'/api/json',
        %args,
        sub {
            my ($body, $header) = @_;
            
            unless (ref($header) eq 'HASH') {
                $@ = '$header is not hash ref';
                $cb->();
                return;
            }
            
            unless ($header->{Status} eq '200') {
                unless ($@) {
                    $@ = $header->{Reason};
                }
                
                $cb->();
                return;
            }
            
            eval {
                $body = $JSON->decode($body);
            };
            if ($@) {
                $logger->error($@);
                $cb->();
            }
            else {
                $cb->($body);
            }
        };
}

sub JenkinsJobForRepo {
    my ($repo, $pull_request, $what) = @_;
    
    unless ($repo) {
        confess 'Invalid $repo given';
    }
    unless ($pull_request > 0) {
        confess 'Invalid pull request number given';
    }
    unless ($what) {
        confess 'Invalid $what given';
    }

    if ($repo eq 'SoftHSMv1') {
        return 'pull-build-softhsm-softhsmv1-'.$pull_request;
    }
    elsif ($repo eq 'opendnssec-workflow-test') {
        return 'pull-build-opendnssec-odswft-'.$pull_request;
    }
    else {
        confess 'Unknown repo '.$repo;
    }
}

sub CheckPullRequests {
    my ($repo, $cb) = @_;
    
    # Get pull requests
    GitHubRequest(
        'repos/opendnssec/'.$repo.'/pulls',
        sub {
            my ($pulls) = @_;
            
            if ($@) {
                $@ = 'request failed: '.$@;
                $cb->();
                return;
            }
            
            unless (ref($pulls) eq 'ARRAY') {
                $@ = 'response is invalid';
                $cb->();
                return;
            }
            
            foreach my $pull (@$pulls) {
                unless (VerifyPullRequest($pull)) {
                    next;
                }
                
                if (exists $pull_request{$repo}->{$pull->{number}}
                    or $pull->{merged_at})
                {
                    next;
                }
                
                $logger->info('New pull request for ', $repo, ' number ', $pull->{number});
                
                {
                    my $pull = $pull;
                    my $lock = 0;
                    my $state = {};
                    $pull_request{$repo}->{$pull->{number}} = AnyEvent->timer(
                        after => 1,
                        interval => $CFG{CHECK_PULL_REQUEST_INTERVAL},
                        cb => sub {
                            if ($lock) {
                                $logger->info('CheckPullRequest ', $repo, ' ', $pull->{number}, ' locked?');
                                return;
                            }
                            unless (isWithinOperationHours()) {
                                return;
                            }
                            
                            $lock = 1;
                            $logger->info('CheckPullRequest ', $repo, ' ', $pull->{number}, ' start');
                            undef($@);
                            CheckPullRequest({
                                repo => $repo,
                                pull => $pull,
                                cb => sub {
                                    if ($@) {
                                        $logger->error('CheckPullRequest ', $repo, ' ', $pull->{number}, ' ', $@);
                                        undef($@);
                                    }
                                    else {
                                        $logger->info('CheckPullRequest ', $repo, ' ', $pull->{number}, ' finish');
                                    }
                                    $lock = 0;
                                },
                                state => $state
                            });
                        });
                }
            }
            $cb->();
        });
}

sub CheckPullRequest {
    my ($d) = @_;
    
    # Get comments
    GitHubRequest(
        $d->{pull}->{_links}->{comments}->{href},
        sub {
            CheckPullRequest_GetComments($d, @_);
        });
}

sub CheckPullRequest_GetComments {
    my ($d, $comments) = @_;

    if ($@) {
        $@ = 'comments request failed: '.$@;
        $d->{cb}->();
        return;
    }

    unless (ref($comments) eq 'ARRAY') {
        $@ = 'comments response is invalid';
        $d->{cb}->();
        return;
    }
    
    foreach my $comment (@$comments) {
        unless (VerifyReviewComment($comment)) {
            $@ = 'Comment not valid';
            $d->{cb}->();
            return;
        }
    }
    
    my ($build, $at);
    foreach my $comment (sort {$a->{created_at} cmp $b->{created_at}} @$comments) {
        unless (exists $CFG{REVIEWER}->{$comment->{user}->{login}}) {
            next;
        }
        
        if ($comment->{body} =~ /^\s*bot\s+build\s*$/o) {
            $build = 1;
            $at = $comment->{created_at};
        }
    }
    
    unless ($build) {
        $logger->info('PullRequest ', $d->{pull}->{number}, ': No build command');
        $d->{cb}->();
        return;
    }
    
    $d->{build_at} = $at;

    # Get pull request status
    GitHubRequest(
        $d->{pull}->{_links}->{statuses}->{href},
        sub {
            CheckPullRequest_GetStatuses($d, @_);
        });
}

sub CheckPullRequest_GetStatuses {
    my ($d, $statuses) = @_;

    if ($@) {
        $@ = 'statuses request failed: '.$@;
        $d->{cb}->();
        return;
    }

    unless (ref($statuses) eq 'ARRAY') {
        $@ = 'statuses response is invalid';
        $d->{cb}->();
        return;
    }
    
    foreach my $status (@$statuses) {
        unless (VerifyStatus($status)) {
            $@ = 'Status not valid';
            $d->{cb}->();
            return;
        }
    }

    my $status;
    foreach my $entry (sort {$b->{created_at} cmp $a->{created_at}} @$statuses) {
        if ($entry->{creator}->{login} eq $CFG{GITHUB_USERNAME}) {
            $status = $entry;
            last;
        }
    }
    
    # If no status, build
    unless ($status) {
        $d->{build} = 1;
        CheckPullRequest_StartBuild($d);
        return;
    }

    # If pending, check build status
    if ($status->{state} eq 'pending') {
        if ($status->{description} =~ /^\s*Build\s+(\d+)\s+pending/o) {
        }
    }
    # If success or failure, check last build command date if newer and build
    elsif ($status->{state} eq 'success'
        or $status->{state} eq 'failure')
    {
        # TODO
        if ($status->{description} =~ /^\s*Build\s+(\d+)\s+(?:successful|failed)/o) {
            my $build_number = $1;
            
            if ($d->{build_at} ge $status->{created_at}) {
                $d->{build} = 1;
                CheckPullRequest_CheckJobs($d);
                return;
            }
            
            $d->{cb}->();
            return;
        }
    }

    $@ = 'Invalid status';
    $d->{cb}->();
}

sub CheckPullRequest_CheckJobs {
    my $d = @_;
    
    $d->{cb}->();
}
    
#    my %jobs = JenkinsJobsForRepo($d);
#    
#    if ($d->{repo})
#    
#    
#    JenkinsRequest(
#        JenkinsJobForRepo($d->{repo}, $d->{pull}->{number}),
#        sub {
#            CheckPullRequest_GetJenkinsJob($d, @_);
#        });
#}
#
#sub CheckPullRequest_GetJenkinsJob {
#    my ($d, $job) = @_;
#    
#    if ($@) {
#        if ($@ =~ /Not found/o) {
#            CheckPullRequest_CreateJenkinsJobs($d);
#            return;
#        }
#        
#        $@ = 'jenkins job request failed: '.$@;
#        $d->{cb}->();
#        return;
#    }
#    
#    unless (ref($job) eq 'HASH') {
#        $@ = 'jenkins job response is invalid';
#        $d->{cb}->();
#        return;
#    }
#
#    use Data::Dumper;
#    print Dumper($job);
#}
#
#sub CheckPullRequest_CreateJenkinsJobs {
#    
#}

__END__

=head1 NAME

exec - Description

=head1 SYNOPSIS

exec [options]

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=back

=head1 DESCRIPTION

...

=cut

