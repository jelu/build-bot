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
use MIME::Base64 ();
use GDBM_File;

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
my %_GITHUB_CACHE;
my %_GITHUB_CACHE_TS;
tie %_GITHUB_CACHE, 'GDBM_File', 'github.db', &GDBM_WRCREAT, 0640;

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

push(@watchers, AnyEvent->timer(
    after => 300,
    interval => 3600,
    cb => sub {
        $logger->info('Expiring GitHub cache');
        my $time = time - $CFG{GITHUB_CACHE_EXPIRE};
        foreach my $url (keys %_GITHUB_CACHE_TS) {
            if ($_GITHUB_CACHE_TS{$url} < $time) {
                delete $_GITHUB_CACHE{$url.':etag'};
                delete $_GITHUB_CACHE{$url.':data'};
                delete $_GITHUB_CACHE_TS{$url};
            }
        }
    }));

foreach my $repo (keys %{$CFG{GITHUB_REPO}}) {
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
untie %_GITHUB_CACHE;
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
    my $method = delete $args{method} || 'GET';
    
    $url =~ s/^https:\/\/api.github.com\///o;
    $args{headers}->{Accept} = 'application/vnd.github.v3';
    $args{headers}->{'User-Agent'} = 'curl/7.32.0';
    $args{headers}->{Authorization} = 'Basic '.MIME::Base64::encode($CFG{GITHUB_USERNAME}.':'.$CFG{GITHUB_TOKEN}, '');
    if ($method eq 'GET' and exists $_GITHUB_CACHE{$url.':etag'}) {
        $args{headers}->{'If-None-Match'} = $_GITHUB_CACHE{$url.':etag'};
        $_GITHUB_CACHE_TS{$url} = time;
    }
    
    $logger->debug('GitHubRequest ', $method, ' https://api.github.com/'.$url);
    AnyEvent::HTTP::http_request $method, 'https://api.github.com/'.$url,
        %args,
        sub {
            my ($body, $header) = @_;
            
            unless (ref($header) eq 'HASH') {
                $@ = '$header is not hash ref';
                $cb->();
                return;
            }
            
            if ($header->{Status} eq '304') {
                $logger->debug('GitHubRequest ', 'https://api.github.com/'.$url, ' 304 cached');
                $body = $_GITHUB_CACHE{$url.':data'};
            }
            elsif ($header->{Status} =~ /^2/o) {
                if ($method eq 'GET' and $header->{etag}) {
                    $_GITHUB_CACHE{$url.':etag'} = $header->{etag};
                    $_GITHUB_CACHE{$url.':data'} = $body;
                    $_GITHUB_CACHE_TS{$url} = time;
                    $logger->debug('GitHubRequest ', 'https://api.github.com/'.$url, ' cached');
                }
            }
            else {
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
                $cb->($body, $header);
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
        and defined $pull->{_links}->{statuses}->{href}
        and ref($pull->{base}) eq 'HASH'
        and defined $pull->{base}->{ref}
        and ref($pull->{base}->{repo}) eq 'HASH'
        and defined $pull->{base}->{repo}->{name}
        and defined $pull->{base}->{repo}->{clone_url}
        and ref($pull->{head}) eq 'HASH'
        and defined $pull->{head}->{ref}
        and ref($pull->{head}->{repo}) eq 'HASH'
        and defined $pull->{head}->{repo}->{clone_url})
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
    my $method = delete $args{method} || 'GET';
    my $no_json = delete $args{no_json};
    
    $url =~ s/^https:\/\/jenkins.opendnssec.org\///o;
    unless ($url =~ /\?/o) {
        $url =~ s/\/+$//o;
        $url .= '/api/json';
    }
    $args{headers}->{'User-Agent'} = 'curl/7.32.0';
    $args{headers}->{Authorization} = 'Basic '.MIME::Base64::encode($CFG{JENKINS_USERNAME}.':'.$CFG{JENKINS_TOKEN}, '');
    
    $logger->debug('JenkinsRequest ', $method, ' https://jenkins.opendnssec.org/'.$url);

    AnyEvent::HTTP::http_request $method, 'https://jenkins.opendnssec.org/'.$url,
        %args,
        sub {
            my ($body, $header) = @_;
            
            unless (ref($header) eq 'HASH') {
                $@ = '$header is not hash ref';
                $cb->();
                return;
            }
            
            unless ($header->{Status} =~ /^2/) {
                unless ($@) {
                    $@ = $header->{Reason};
                }
                
                $cb->();
                return;
            }
            
            if ($no_json) {
                $cb->(1, $header);
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
                $cb->($body, $header);
            }
        };
}

sub ResolveDefines {
    my ($string, $define) = @_;
    
    # TODO: verify args
    
    foreach my $key (keys %$define) {
        $string =~ s/\@$key\@/$define->{$key}/mg;
    }
    
    return $string;
}

sub ReadTemplate {
    my ($template, $define) = @_;
    
    # TODO: verify args
    
    local($/) = undef;
    local(*FILE);
    open(FILE, 'template/'.$template.'.xml') or confess 'open '.$template.' failed: '.$!;
    my $string = <FILE>;
    close(FILE);
    
    if (exists $define->{CHILDS}) {
        $string =~ s/\@NO_CHILDS_(?:START|END)\@//mgo;
    }
    else {
        $string =~ s/\@NO_CHILDS_START\@.*\@NO_CHILDS_END\@//mgo;
    }
    
    return ResolveDefines($string, $define);
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
                    my $state = {
                        define => {
                            BASE => $CFG{GITHUB_REPO}->{$repo}->{base},
                            ORIGIN => $pull->{base}->{repo}->{name},
                            ORIGIN_GIT => $pull->{base}->{repo}->{clone_url},
                            ORIGIN_BRANCH => $pull->{base}->{ref},
                            PR => $pull->{base}->{repo}->{name}.'-'.$pull->{number},
                            PR_GIT => $pull->{head}->{repo}->{clone_url},
                            PR_BRANCH => $pull->{head}->{ref}
                        }
                    };
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
        CheckPullRequest_CheckJobs($d);
        return;
    }
    # If pending, check build status
    if ($status->{state} eq 'pending') {
        if ($status->{description} =~ /^\s*Build\s+(\d+)\s+pending/o) {
            $d->{build_number} = $1;
            $d->{build} = 0;
            CheckPullRequest_CheckJobs($d);
            return;
        }
    }
    # If success or failure, check last build command date if newer and build
    elsif ($status->{state} eq 'success'
        or $status->{state} eq 'failure')
    {
        if ($status->{description} =~ /^\s*Build\s+(\d+)\s+(?:successful|failed)/o) {
            my $build_number = $1;
            
            if ($d->{build_at} ge $status->{created_at}) {
                $d->{build} = 1;
                CheckPullRequest_StartBuild($d);
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
    my ($d) = @_;
    # TODO: Check $CFG
    my @jobs = @{$CFG{JENKINS_JOBS}->{$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}}};

    # TODO: verify jobs
    
    my $code; $code = sub {
        my $job = shift(@jobs);
        unless (defined $job) {
            CheckPullRequest_StartBuild($d);
            undef $code;
            return;
        }
        my $define = {
            %{$d->{state}->{define}},
            (exists $job->{define} ? (%{$job->{define}}) : ())
        };
        if (exists $job->{childs}) {
            $define->{CHILDS} = ResolveDefines($job->{childs}, $define);
        }
        my $name = ResolveDefines($job->{name}, $define);
        
        unless (exists $d->{build_job}) {
            $d->{build_job} = $name;
        }
        
        # Check if job exists and status, create if not
        JenkinsRequest(
            'job/'.$name,
            sub {
                if ($@) {
                    if ($@ =~ /not found/io) {
                        undef $@;
                        
                        # Create job
                        JenkinsRequest(
                            'createItem?name='.$name,
                            sub {
                                if ($@) {
                                    $@ = 'jenkins create job failed: '.$@;
                                    $d->{cb}->();
                                    undef $code;
                                    return;
                                }
                                
                                $logger->info('Created jenkins job ', $name);
                                $code->();
                            },
                            headers => {
                                'Content-Type' => 'text/xml'
                            },
                            no_json => 1,
                            method => 'POST',
                            body => ReadTemplate($job->{template}, $define));
                        return;
                    }
                    
                    $@ = 'jenkins job request failed: '.$@;
                    $d->{cb}->();
                    undef $code;
                    return;
                }
                
                unless (ref($job) eq 'HASH') {
                    $@ = 'jenkins job response is invalid';
                    $d->{cb}->();
                    undef $code;
                    return;
                }
                
                # TODO: check logic
                # save this json
                # request lastBuild->url
                # save that json
                
                $code->();
            });
    };
    $code->();
}

sub CheckPullRequest_StartBuild {
    my ($d) = @_;
    
    if ($d->{build}) {
        unless ($d->{build_job}) {
            $@ = 'start job failed: dont know which';
            $d->{cb}->();
            return;
        }
        
        JenkinsRequest(
            'job/'.$d->{build_job}.'/build?delay=0sec',
            sub {
                my (undef, $header) = @_;
                
                if ($@) {
                    $@ = 'jenkins start job failed: '.$@;
                    $d->{cb}->();
                    return;
                }
                
                JenkinsRequest(
                    $header->{location},
                    sub {
                        my ($job) = @_;

                        if ($@) {
                            $@ = 'jenkins start job failed (queue): '.$@;
                            $d->{cb}->();
                            return;
                        }
                        
                        unless (ref($job) eq 'HASH'
                            and ref($job->{executable}) eq 'HASH'
                            and defined $job->{executable}->{number}
                            and defined $job->{executable}->{url})
                        {
                            $@ = 'jenkins start job request invalid (queue)';
                            $d->{cb}->();
                            return;
                        }
                        
                        $d->{build_number} = $job->{executable}->{number};
                        $d->{build_url} = $job->{executable}->{url};
                        $logger->info('Started jenkins job ', $d->{build_job}, ' number ', $d->{build_number});
                        CheckPullRequest_UpdateStatus($d);
                    });
            },
            no_json => 1);
        return;
    }
    
    CheckPullRequest_UpdateStatus($d);
}

sub CheckPullRequest_UpdateStatus {
    my ($d) = @_;
    
    if ($d->{build}) {
        unless (defined $d->{build_number}) {
            $@ = 'no build number when update status after build?';
            $d->{cb}->();
            return;
        }
        GitHubRequest(
            $d->{pull}->{_links}->{statuses}->{href},
            sub {
                if ($@) {
                    $@ = 'status update failed: '.$@;
                    $d->{cb}->();
                    return;
                }
                $logger->info('Status pending for ', $d->{repo}, ' number ', $d->{pull}->{number});
                $d->{cb}->();
                return;
            },
            method => 'POST',
            body => $JSON->encode({
                state => 'pending',
                target_url => (exists $d->{build_url} ? $d->{build_url} : 'https://jenkins.opendnssec.org'),
                description => 'Build '.$d->{build_number}.' pending'
            }));
        return;
    }
    
    # TODO:
    # verify saved json from CheckJobs
    # relate lastBuild json with upstreamProject and upstreamBuild
    # check result == SUCCESS
    # warn when upstreamBuild is > what we are checking for
    
    $d->{cb}->();
}

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

