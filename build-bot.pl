#!/usr/bin/env perl
#
# Copyright (c) 2014 OpenDNSSEC AB (svb). All rights reserved.

# TODO: add error check per unique call, if call fails more then X set status to error if possible
# TODO: build bot commands:
#    test - build and test only modified tests, if no modified tests then test all
#    merge - run build and merge if success
#    build merge - same as merge
#    test merge - run test and merge if success
# TODO: reload config on HUP, remove old repos if removed from config, delete pull request watchers
# TODO: Scan Jenkins for old pull request, check GitHub if closed and clean up

use common::sense;
use Carp;

use EV ();
use AnyEvent ();
use AnyEvent::HTTP ();

use Pod::Usage ();
use Getopt::Long ();
use Log::Log4perl ();
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
    LOG_GITHUB_REQUEST => 0,
    LOG_JENKINS_REQUEST => 0,
    
    CHECK_PULL_REQUESTS_INTERVAL => 300,
    CHECK_PULL_REQUEST_INTERVAL => 600,
    CHECK_JENKINS_INTERVAL => 30,

    TRY_DELETE_JOB => 10,
    CLEANUP_JOB_PATTERN => undef,

    REVIEWER => {
    },
    
    # GITHUB_USERNAME
    # GITHUB_TOKEN
    GITHUB_REPO => {
        # repo =>
        #   jobs =>
        #   base =>
        #   access =>
        #     user =>
    },
    GITHUB_CACHE_EXPIRE => 7200,

    JENKINS_URL_BASE => 'https://jenkins.opendnssec.org/',
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
my %delete_pull_request;
my $jenkins_enabled = 0;
my %_GITHUB_CACHE;
my %_GITHUB_CACHE_TS;

Getopt::Long::GetOptions(
    'help|?' => \$help,
    'log4perl:s' => \$log4perl,
    'daemon' => \$daemon,
    'pidfile:s' => \$pidfile,
    'config=s' => \$config
) or Pod::Usage::pod2usage(2);
Pod::Usage::pod2usage(1) if $help;
unless ($config) {
    Pod::Usage::pod2usage(1);
}

{
    my $CFG;
    eval {
        $CFG = YAML::LoadFile($config);
    };
    if ($@ or !defined $CFG or ref($CFG) ne 'HASH') {
        confess 'Unable to load config file ', $config, ': ', $@;
    }
    %CFG = ( %CFG, %$CFG );
    VerifyCFG();
}

if (defined $log4perl and -f $log4perl) {
    Log::Log4perl->init($log4perl);
}
elsif ($daemon) {
    Log::Log4perl->init( \q(
    log4perl.logger                    = DEBUG, SYSLOG
    log4perl.appender.SYSLOG           = Log::Dispatch::Syslog
    log4perl.appender.SYSLOG.min_level = debug
    log4perl.appender.SYSLOG.ident     = build-bot.pl
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

tie %_GITHUB_CACHE, 'GDBM_File', 'github.db', &GDBM_WRCREAT, 0640;
foreach my $key (keys %_GITHUB_CACHE) {
    $key =~ s/:(?:etag|data)$//o;
    $_GITHUB_CACHE_TS{$key} = time;
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

{
    my $lock;
    push(@watchers, AnyEvent->timer(
        after => 1,
        interval => $CFG{CHECK_JENKINS_INTERVAL},
        cb => sub {
            if ($lock) {
                $logger->info('CheckJenkins locked?');
                return;
            }
            unless (isWithinOperationHours()) {
                return;
            }
            
            $lock = 1;
            $logger->info('CheckJenkins start');
            undef($@);
            CheckJenkins(sub {
                if ($@) {
                    $logger->error('CheckJenkins ', $@);
                    undef($@);
                }
                else {
                    $logger->info('CheckJenkins finish');
                }
                $lock = 0;
            });
        }));
}

my $after = 2;
foreach my $repo (keys %{$CFG{GITHUB_REPO}}) {
    my $lock = 0;
    $delete_pull_request{$repo} = {};
    push(@watchers, AnyEvent->timer(
        after => $after,
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
    $after += 3;
}

$cv->recv;
$logger->info($0, ' stopping');
@watchers = ();
%pull_request = ();
untie %_GITHUB_CACHE;
exit(0);

#
# Verify all the configuration in %CFG
#

sub VerifyCFG {
    foreach my $required (qw(
CHECK_PULL_REQUESTS_INTERVAL
CHECK_PULL_REQUEST_INTERVAL
CHECK_JENKINS_INTERVAL
TRY_DELETE_JOB
GITHUB_CACHE_EXPIRE))
    {
        unless (defined $CFG{$required} and $CFG{$required} =~ /^\d+$/o) {
            confess 'Missing or not integer required configuration '.$required;
        }
    }

    foreach my $required (qw(
GITHUB_USERNAME
GITHUB_TOKEN
JENKINS_URL_BASE
JENKINS_USERNAME
JENKINS_TOKEN
OPERATION_START
OPERATION_END
TEMPLATE_PATH
CLEANUP_JOB_PATTERN))
    {
        unless (defined $CFG{$required} and $CFG{$required}) {
            confess 'Missing or empty required configuration '.$required;
        }
    }

    foreach my $required (qw(
REVIEWER
GITHUB_REPO
JENKINS_JOBS))
    {
        unless (defined $CFG{$required} and ref($CFG{$required}) eq 'HASH') {
            confess 'Missing or not HASH for required configuration '.$required;
        }
    }
    
    foreach (keys %{$CFG{GITHUB_REPO}}) {
        unless (ref($CFG{GITHUB_REPO}->{$_}) eq 'HASH') {
            confess 'GITHUB_REPO entry '.$_.' invalid, not a HASH';
        }

        foreach my $required (qw(jobs base)) {
            unless (defined $CFG{GITHUB_REPO}->{$_}->{$required} and $CFG{GITHUB_REPO}->{$_}->{$required}) {
                confess 'Missing or empty required configuration '.$required.' in GITHUB_REPO entry '.$_;
            }
        }
        
        if (exists $CFG{GITHUB_REPO}->{$_}->{access} and ref($CFG{GITHUB_REPO}->{$_}->{access}) ne 'HASH') {
            confess 'Entry "access" in GITHUB_REPO '.$_.' invalid, not a HASH';
        }
    }

    foreach (keys %{$CFG{JENKINS_JOBS}}) {
        unless (ref($CFG{JENKINS_JOBS}->{$_}) eq 'ARRAY') {
            confess 'JENKINS_JOBS entry '.$_.' invalid, not an ARRAY';
        }

        foreach my $job (@{$CFG{JENKINS_JOBS}->{$_}}) {
            unless (ref($job) eq 'HASH') {
                confess 'Entry in JENKINS_JOBS '.$_.' invalid, not a HASH';
            }
            
            foreach my $required (qw(name template)) {
                unless (defined $job->{$required} and $job->{$required}) {
                    confess 'Missing or empty required configuration '.$required.' in JENKINS_JOBS entry '.$_;
                }
            }
            
            if (exists $job->{define} and ref($job->{define}) ne 'HASH') {
                confess 'Entry "define" in JENKINS_JOBS '.$_.' invalid, not a HASH';
            }
        }
    }
}

#
# Return true if we are within operation hours
#

sub isWithinOperationHours {
    my $now = strftime('%H:%M', gmtime);
    
    if ($now ge $CFG{OPERATION_START} and $now lt $CFG{OPERATION_END}) {
        return 1;
    }
    
    return;
}

#
# Make a API request to GitHub
#

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
    
    $CFG{LOG_GITHUB_REQUEST} and $logger->debug('GitHubRequest ', $method, ' https://api.github.com/'.$url);
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
                $CFG{LOG_GITHUB_REQUEST} and $logger->debug('GitHubRequest ', 'https://api.github.com/'.$url, ' 304 cached');
                $body = $_GITHUB_CACHE{$url.':data'};
            }
            elsif ($header->{Status} =~ /^2/o) {
                if ($method eq 'GET' and $header->{etag}) {
                    $_GITHUB_CACHE{$url.':etag'} = $header->{etag};
                    $_GITHUB_CACHE{$url.':data'} = $body;
                    $_GITHUB_CACHE_TS{$url} = time;
                    $CFG{LOG_GITHUB_REQUEST} and $logger->debug('GitHubRequest ', 'https://api.github.com/'.$url, ' cached');
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

#
# Verify the pull request response from GitHub
#

sub VerifyPullRequest {
    my ($pull) = @_;
    
    unless (ref($pull) eq 'HASH'
        and ref($pull->{user}) eq 'HASH'
        and defined $pull->{user}->{login}
        and defined $pull->{created_at}
        and defined $pull->{number}
        and defined $pull->{patch_url}
        and defined $pull->{url}
        and defined $pull->{comments_url}
        and defined $pull->{statuses_url}
        and exists $pull->{merged_at}
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

#
# Verify comment response from GitHub
#

sub VerifyComment {
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

#
# Verify commit response from GitHub
#

sub VerifyCommit {
    my ($commit) = @_;
    
    unless (ref($commit) eq 'HASH'
        and defined $commit->{sha}
        and ref($commit->{commit}) eq 'HASH'
        and ref($commit->{commit}->{author}) eq 'HASH'
        and defined $commit->{commit}->{author}->{date}
        and ref($commit->{commit}->{committer}) eq 'HASH'
        and defined $commit->{commit}->{committer}->{date}
        and ref($commit->{parents}) eq 'ARRAY')
    {
        return;
    }
    
    foreach (@{$commit->{parents}}) {
        unless (ref($_) eq 'HASH' and defined $_->{sha}) {
            return;
        }
    }
    
    return 1;
}

#
# Verify status response from GitHub
#

sub VerifyStatus {
    my ($status) = @_;
    
    unless (ref($status) eq 'HASH'
        and defined $status->{url}
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

#
# Make a API request to Jenkins
#

sub JenkinsRequest {
    my $url = shift;
    my $cb = shift;
    my %args = ( @_ );
    my $method = delete $args{method} || 'GET';
    my $no_json = delete $args{no_json};
    
    $url =~ s/^$CFG{JENKINS_URL_BASE}//;
    unless ($url =~ /\?/o) {
        $url =~ s/\/+$//o;
        $url .= '/api/json';
    }
    $args{headers}->{'User-Agent'} = 'curl/7.32.0';
    $args{headers}->{Authorization} = 'Basic '.MIME::Base64::encode($CFG{JENKINS_USERNAME}.':'.$CFG{JENKINS_TOKEN}, '');
    
    $CFG{LOG_JENKINS_REQUEST} and $logger->debug('JenkinsRequest ', $method, ' '.$CFG{JENKINS_URL_BASE}.$url);
    AnyEvent::HTTP::http_request $method, $CFG{JENKINS_URL_BASE}.$url,
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
                $cb->($body, $header);
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

#
# Verify job response from Jenkins
#

sub VerifyJobData {
    my ($data) = @_;
    
    unless (ref($data) eq 'HASH'
        and ((
                exists $data->{lastBuild}
                and !defined $data->{lastBuild}
            )
            or (
                ref($data->{lastBuild}) eq 'HASH'
                and defined $data->{lastBuild}->{number}
                and defined $data->{lastBuild}->{url}
            ))
        )
    {
        return;
    }
    
    return 1;
}

#
# Verify build response from Jenkins
#

sub VerifyBuildData {
    my ($data) = @_;
    
    unless (ref($data) eq 'HASH'
        and defined $data->{number}
        and exists $data->{result}
        and defined $data->{url}
        and ref($data->{actions}) eq 'ARRAY')
    {
        return;
    }
    
    return 1;
}

#
# Verify test report response from Jenkins
#

sub VerifyTestReport {
    my ($data) = @_;
    
    unless (ref($data) eq 'HASH'
        and defined $data->{totalCount}
        and exists $data->{failCount})
    {
        return;
    }
    
    return 1;
}

#
# Verify cause response from Jenkins
#

sub VerifyCause {
    my ($cause) = @_;
    
    unless (ref($cause) eq 'HASH'
        and defined $cause->{upstreamProject}
        and defined $cause->{upstreamBuild})
    {
        return;
    }
    
    return 1;
}

#
# Resolve defined values (@TOKEN@)in $string with the help from $define (hash ref)
#

sub ResolveDefines {
    my ($string, $define) = @_;
    
    unless (ref($define) eq 'HASH') {
        confess '$define is not HASH';
    }
    
    foreach my $key (keys %$define) {
        $string =~ s/\@$key\@/$define->{$key}/mg;
    }
    
    return $string;
}

#
# Read a template file and resolve the defined values and return the result as a string
#

sub ReadTemplate {
    my ($template, $define) = @_;
    
    unless (-r $CFG{TEMPLATE_PATH}.'/'.$template.'.xml') {
        confess '$template ['.$template.'] is not a file or can not be read';
    }
    unless (ref($define) eq 'HASH') {
        confess '$define is not HASH';
    }
    
    local($/) = undef;
    local(*FILE);
    open(FILE, $CFG{TEMPLATE_PATH}.'/'.$template.'.xml') or confess 'open '.$template.' failed: '.$!;
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

#
# Check if we have new pull requests to monitor
#

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

            my %have_pull;
            my $after = 2;
            foreach my $pull (@$pulls) {
                unless (VerifyPullRequest($pull)) {
                    next;
                }
                
                if ($pull->{merged_at}) {
                    next;
                }

                if (exists $pull_request{$repo}->{$pull->{number}}) {
                    $have_pull{$pull->{number}} = 1;
                    next;
                }
                
                $logger->info('New pull request for ', $repo, ' number ', $pull->{number});
                
                {
                    my $pull = $pull;
                    my $lock = 0;
                    # Define a state hash that will be given for each run of the timer
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
                    $have_pull{$pull->{number}} = 1;
                    $pull_request{$repo}->{$pull->{number}} = AnyEvent->timer(
                        after => $after,
                        interval => $CFG{CHECK_PULL_REQUEST_INTERVAL},
                        cb => sub {
                            if ($lock) {
                                $logger->info('CheckPullRequest ', $repo, ' ', $pull->{number}, ' locked?');
                                return;
                            }
                            unless (isWithinOperationHours()) {
                                return;
                            }
                            unless ($jenkins_enabled) {
                                $logger->warn('CheckPullRequest ', $repo, ' ', $pull->{number}, ': Jenkins is disabled, will not do anything');
                                return;
                            }
                            
                            $lock = 1;
                            if (exists $delete_pull_request{$repo}->{$pull->{number}} and $state->{state} ne 'pending') {
                                $logger->info('DeletePullRequest ', $repo, ' ', $pull->{number}, ' start');
                                undef($@);
                                DeletePullRequest({
                                    repo => $repo,
                                    pull => $pull,
                                    cb => sub {
                                        if ($@) {
                                            $logger->error('DeletePullRequest ', $repo, ' ', $pull->{number}, ' ', $@);
                                            undef($@);
                                            if ($delete_pull_request{$repo}->{$pull->{number}} <= $CFG{TRY_DELETE_JOB}) {
                                                $delete_pull_request{$repo}->{$pull->{number}}++;
                                                $lock = 0;
                                                return;
                                            }
                                        }
                                        else {
                                            $logger->info('DeletePullRequest ', $repo, ' ', $pull->{number}, ' finish');
                                        }
                                        $lock = 0;
                                        delete $delete_pull_request{$repo}->{$pull->{number}};
                                        delete $pull_request{$repo}->{$pull->{number}};
                                    },
                                    state => $state
                                });
                                return;
                            }
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
                    $after += 3;
                }
            }
            
            foreach my $number (keys %{$pull_request{$repo}}) {
                unless (exists $have_pull{$number} and !exists $delete_pull_request{$repo}->{$number}) {
                    $logger->info('Marking pull request ', $repo, ' ', $number, ' for deletion');
                    $delete_pull_request{$repo}->{$number} = 1;
                }
            }
            $cb->();
        });
}

#
# Monitor a pull request for change and/or commands
#

sub CheckPullRequest {
    my ($d) = @_;

    # Get comments
    GitHubRequest(
        $d->{pull}->{comments_url},
        sub {
            CheckPullRequest_GetComments($d, @_);
        });
}

#
# Get the comments for the pull request to look for bot commands
#

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
        unless (VerifyComment($comment)) {
            $@ = 'Comment not valid';
            $d->{cb}->();
            return;
        }
    }
    
    my ($build, $at, $command);
    foreach my $comment (sort {$a->{created_at} cmp $b->{created_at}} @$comments) {
        if ($comment->{body} =~ /#((?:build))(?:\s|$)/mo) {
            $command = $1;

            if (exists $CFG{REVIEWER}->{$comment->{user}->{login}}) {
                # catch REVIEWER access first
            }
            elsif (exists $CFG{GITHUB_REPO}->{$d->{repo}}->{access}) {
                my %access;
                if (exists $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{$comment->{user}->{login}}) {
                    %access = map { $_ => 1 } split(/[\s,]+/o, $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{$comment->{user}->{login}});
                }
                elsif (exists $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{'*'}) {
                    %access = map { $_ => 1 } split(/[\s,]+/o, $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{'*'});
                }
                else {
                    undef $command;
                    next;
                }
    
                unless ($access{all} or exists $access{$command}) {
                    undef $command;
                    next;
                }
            }
            else {
                # No access
                undef $command;
                next;
            }
            
            $build = 1;
            $at = $comment->{created_at};
        }
    }
    
    # If no command check for autobuild
    unless ($command) {
        if (exists $CFG{GITHUB_REPO}->{$d->{repo}}->{access}) {
            my %access;
            if (exists $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{$d->{pull}->{user}->{login}}) {
                %access = map { $_ => 1 } split(/[\s,]+/o, $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{$d->{pull}->{user}->{login}});
            }
            elsif (exists $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{'*'}) {
                %access = map { $_ => 1 } split(/[\s,]+/o, $CFG{GITHUB_REPO}->{$d->{repo}}->{access}->{'*'});
            }
            
            if (exists $access{autobuild}) {
                $at = $d->{pull}->{created_at};
                $build = 1;
                $d->{autobuild} = 1;
            }
        }
    }
    
    unless ($build) {
        $logger->info('PullRequest ', $d->{pull}->{number}, ': No build command');
        $d->{cb}->();
        return;
    }
    
    $logger->debug('PullRequest ', $d->{pull}->{number}, ': build at ', $at);
    $d->{build_at} = $at;

    # Get pull request commits
    GitHubRequest(
        $d->{pull}->{url}.'/commits',
        sub {
            CheckPullRequest_GetCommits($d, @_);
        });
}

#
# Get a list of commits for the pull request to retrieve statuses from
#

sub CheckPullRequest_GetCommits {
    my ($d, $commits) = @_;

    if ($@) {
        $@ = 'commits request failed: '.$@;
        $d->{cb}->();
        return;
    }

    unless (ref($commits) eq 'ARRAY') {
        $@ = 'commits response is invalid';
        $d->{cb}->();
        return;
    }
    
    my (%commit, %parent);
    foreach my $commit (@$commits) {
        unless (VerifyCommit($commit)) {
            $@ = 'Commit not valid';
            $d->{cb}->();
            return;
        }
        
        # Check author and committer date to see if any commit or rebased
        # commit has been issues after the build command
        my $date = $commit->{commit}->{author}->{date};
        if ($commit->{commit}->{committer}->{date} gt $date) {
            $date = $commit->{commit}->{committer}->{date};
        }
        
        if ($date ge $d->{build_at}) {
            # There is a commit after or at the build command, log it
            $d->{commit_after_build} = 1;
        }
        
        # Store all commits and parents to verify the chain and get the last commit
        $commit{$commit->{sha}} = $commit;
        foreach my $parent (@{$commit->{parents}}) {
            $parent{$parent->{sha}} = 1;
        }
    }
    
    # Remove all parent SHAs from %commit, last standing will be the last commit
    foreach my $sha (keys %parent) {
        delete $commit{$sha};
    }
    foreach my $sha (keys %commit) {
        if (defined $d->{last_commit}) {
            $@ = 'multiple last commit found?';
            $d->{cb}->();
            return;
        }
        $d->{last_commit} = $commit{$sha};
    }
    
    unless (defined $d->{last_commit}) {
        $@ = 'no last commit?';
        $d->{cb}->();
        return;
    }
    
    # Get statuses for each commit
    my @href = split(/\//o, $d->{pull}->{statuses_url});
    pop(@href);
    $d->{last_commit_status} = join('/', @href, $d->{last_commit}->{sha});
    my @statuses;
    my $code; $code = sub {
        my $commit = shift(@$commits);
        unless (defined $commit) {
            CheckPullRequest_GetStatuses($d, \@statuses);
            undef $code;
            return;
        }
        
        GitHubRequest(
            join('/', @href, $commit->{sha}),
            sub {
                my ($statuses) = @_;

                unless (ref($statuses) eq 'ARRAY') {
                    $@ = 'commit statuses response is invalid';
                    $d->{cb}->();
                    return;
                }
                
                push(@statuses, @$statuses);
                $code->();
            });
    };
    $code->();
}

#
# Get the status for each commit in the pull request and determen what we have done so far
#

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
        if ($d->{commit_after_build}) {
            $logger->info('Commit after build command for ', $d->{repo}, ' number ', $d->{pull}->{number});
            $d->{cb}->();
            return;
        }
        $d->{build} = 1;
        $d->{status} = $d->{last_commit_status};
        unless (defined $d->{state}->{state}) {
            $d->{state}->{state} = 'pending';
        }
        CheckPullRequest_Verify($d);
        return;
    }
    # If pending, check build status
    if ($status->{state} eq 'pending') {
        if ($status->{description} =~ /^\s*Build\s+(\d+)\s+pending/o) {
            $d->{build_number} = $1;
            if ($d->{build_number} < 1) {
                $@ = 'Invalid build number from status';
                $d->{cb}->();
                return;
            }
            $d->{build} = 0;
            $d->{status} = $status->{url};
            unless (defined $d->{state}->{state}) {
                $d->{state}->{state} = 'pending';
            }
            CheckPullRequest_Verify($d);
            return;
        }
    }
    # If success or failure, check last build command date if newer and build
    elsif ($status->{state} eq 'success'
        or $status->{state} eq 'failure'
        or $status->{state} eq 'error')
    {
        my $state;
        if ($status->{description} =~ /^\s*Build\s+(\d+)\s+((?:successful|failed|error))/o) {
            $d->{build_number} = $1;
            $state = $2;
            
            if ($state eq 'successful') {
                $state = 'success';
            }
            elsif ($state eq 'failed') {
                $state = 'failure';
            }
            elsif ($state eq 'error') {
            }
            else {
                undef $state;
            }
            
            if ($d->{build_number} < 1) {
                $@ = 'Invalid build number from status';
                $d->{cb}->();
                return;
            }
        }
        elsif ($status->{description} =~ /^\s*Build\s+error/o) {
            $state = 'error';
        }
        
        if (defined $state and $state eq $status->{state}) {
            unless (defined $d->{state}->{state}) {
                $d->{state}->{state} = $state;
            }

            if ($d->{build_at} ge $status->{created_at} and !$d->{autobuild}) {
                if ($d->{commit_after_build}) {
                    $logger->info('Commit after build command for ', $d->{repo}, ' number ', $d->{pull}->{number});
                    $d->{cb}->();
                    return;
                }
                $d->{build} = 1;
                $d->{status} = $d->{last_commit_status};
                CheckPullRequest_Verify($d);
                return;
            }
            
            $d->{cb}->();
            return;
        }
    }

    $@ = 'Invalid status';
    $d->{cb}->();
}

#
# Verify data and set error if there are any problems
#

sub CheckPullRequest_Verify {
    my ($d) = @_;

    if ($d->{build} or $d->{state}->{state} eq 'pending') {
        if ($d->{pull}->{base}->{ref} =~ /master$/ and !$CFG{GITHUB_REPO}->{$d->{repo}}->{'allow-merge-master'}) {
            CheckPullRequest_UpdateStatus2(
                $d,
                'error',
                $d->{pull}->{url},
                'Build error: Merging into *master not allowed');
            return;
        }
    }
    
    CheckPullRequest_CheckJobs($d);
}

#
# Check all Jenkins jobs, create them if they don't exist otherwise get the latest build info
#

sub CheckPullRequest_CheckJobs {
    my ($d) = @_;
    
    unless (exists $CFG{GITHUB_REPO}->{$d->{repo}}) {
        confess 'GITHUB_REPO '.$d->{repo}.' not found';
    }
    unless (exists $CFG{JENKINS_JOBS}->{$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}}) {
        confess 'JENKINS_JOBS '.$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}.' not found';
    }
    my @jobs = @{$CFG{JENKINS_JOBS}->{$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}}};
    
    $d->{job} = {};
    
    my $code; $code = sub {
        my $job = shift(@jobs);
        unless (defined $job) {
            CheckPullRequest_StartBuild($d);
            undef $code;
            return;
        }
        my $define = {
            %{$d->{state}->{define}},
            (exists $job->{define} ? (%{$job->{define}}) : ()),
            LAST_COMMIT_SHA => $d->{last_commit}->{sha}
        };
        if (exists $job->{childs}) {
            $define->{CHILDS} = ResolveDefines($job->{childs}, $define);
        }
        my $name = ResolveDefines($job->{name}, $define);
        
        unless (exists $d->{build_job}) {
            $d->{build_job} = $name;
            $d->{build_job_define} = $define;
            $d->{build_job_template} = $job->{template};
        }
        
        # Check if job exists and status, create if not
        JenkinsRequest(
            'job/'.$name,
            sub {
                my ($data) = @_;
                
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
                                $d->{job_created} = 1;
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
                
                unless (VerifyJobData($data)) {
                    $@ = 'jenkins job response is invalid';
                    $d->{cb}->();
                    undef $code;
                    return;
                }
                
                unless (defined $data->{lastBuild}) {
                    $d->{job}->{$name} = {
                        childs => $define->{CHILDS},
                        data => $data,
                        build => undef,
                        test => undef
                    };
                    $code->();
                    return;
                }
                
                JenkinsRequest(
                    $data->{lastBuild}->{url},
                    sub {
                        my ($build_data) = @_;
                        
                        if ($@) {
                            $@ = 'jenkins build request failed: '.$@;
                            $d->{cb}->();
                            undef $code;
                            return;
                        }
                        
                        unless (VerifyBuildData($build_data)) {
                            $@ = 'jenkins build response is invalid';
                            $d->{cb}->();
                            undef $code;
                            return;
                        }
                        
                        unless (defined $job->{testReport} and $job->{testReport}) {
                            $d->{job}->{$name} = {
                                childs => $define->{CHILDS},
                                data => $data,
                                build => $build_data,
                                test => undef
                            };
                            $code->();
                            return;
                        }

                        JenkinsRequest(
                            $data->{lastBuild}->{url}.'testReport',
                            sub {
                                my ($test_report) = @_;
                                
                                if ($@) {
                                    $@ = 'jenkins test report request failed: '.$@;
                                    $d->{cb}->();
                                    undef $code;
                                    return;
                                }
                                
                                unless (VerifyTestReport($test_report)) {
                                    $@ = 'jenkins test report response is invalid';
                                    $d->{cb}->();
                                    undef $code;
                                    return;
                                }
                                
                                $d->{job}->{$name} = {
                                    childs => $define->{CHILDS},
                                    data => $data,
                                    build => $build_data,
                                    test => $test_report
                                };
                                $code->();
                            });
                    });
            });
    };
    $code->();
}

#
# Start a build if needed
#

sub CheckPullRequest_StartBuild {
    my ($d) = @_;

    if ($d->{build}) {
        unless ($d->{build_job}) {
            $@ = 'start job failed: dont know which';
            $d->{cb}->();
            return;
        }
        
        unless ($d->{job_created}) {
            unless (exists $d->{job}->{$d->{build_job}}) {
                $@ = 'start job failed: build job did not exist?';
                $d->{cb}->();
                return;
            }

            unless ($d->{build_number}) {
                # If no job has been created and we don't have a build number
                # we might have started a build and failed a status update.
                # Extract build number if so and just do status update.
                
                if ($d->{job}->{$d->{build_job}}->{data}->{lastBuild}) {
                    $d->{build_number} = $d->{job}->{$d->{build_job}}->{data}->{lastBuild}->{number};
                    $d->{force_status_update} = 1;
                    $d->{build} = 0;
                    CheckPullRequest_UpdateStatus($d);
                    return;
                }
            }
        }
        
        if ($d->{build_number}) {
            # If we have a build number from status, check it with lastBuild
            # If lastBuild is larger, extract and update status
            if (exists $d->{job}->{$d->{build_job}}
                and $d->{job}->{$d->{build_job}}->{data}->{lastBuild}
                and $d->{job}->{$d->{build_job}}->{data}->{lastBuild}->{number} > $d->{build_number})
            {
                $d->{build_number} = $d->{job}->{$d->{build_job}}->{data}->{lastBuild}->{number};
                $d->{force_status_update} = 1;
                $d->{build} = 0;
                CheckPullRequest_UpdateStatus($d);
                return;
            }
        }

        # Update job with last commit sha
        JenkinsRequest(
            'job/'.$d->{build_job}.'/config.xml',
            sub {
                if ($@) {
                    $@ = 'jenkins update build job failed: '.$@;
                    $d->{cb}->();
                    return;
                }
                
                $logger->info('Updated jenkins build job ', $d->{build_job}, ' with last commit sha ', $d->{last_commit}->{sha});

                JenkinsRequest(
                    'job/'.$d->{build_job}.'/build?delay=0sec',
                    sub {
                        my (undef, $header) = @_;
                        
                        if ($@) {
                            $@ = 'jenkins start job failed: '.$@;
                            $d->{cb}->();
                            return;
                        }
                        
                        my $w; $w = AnyEvent->timer(
                            after => 1,
                            cb => sub {
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
                                undef $w;
                            });
                    },
                    no_json => 1,
                    method => 'POST');
            },
            headers => {
                'Content-Type' => 'text/xml'
            },
            no_json => 1,
            method => 'POST',
            body => ReadTemplate($d->{build_job_template}, $d->{build_job_define}));
        return;
    }
    
    CheckPullRequest_UpdateStatus($d);
}

#
# Update the status of the pull request
#

sub CheckPullRequest_UpdateStatus {
    my ($d) = @_;
    
    unless (defined $d->{status}) {
        $@ = 'no status url set';
        $d->{cb}->();
        return;
    }
    
    if ($d->{build}) {
        unless (defined $d->{build_number}) {
            $@ = 'no build number when update status after build?';
            $d->{cb}->();
            return;
        }
        
        CheckPullRequest_UpdateStatus2(
            $d,
            'pending',
            (exists $d->{build_url} ? $d->{build_url}.'downstreambuildview/' : 'https://jenkins.opendnssec.org/view/pull-requests/'),
            'Build '.$d->{build_number}.' pending');
        return;
    }

    unless ($d->{build_job}) {
        $@ = 'update status failed: dont know which job';
        $d->{cb}->();
        return;
    }
    unless (exists $d->{job}->{$d->{build_job}}) {
        $@ = 'update status failed: build job did not exist?';
        $d->{cb}->();
        return;
    }
    my $build_job = $d->{job}->{$d->{build_job}};
    unless (defined $build_job->{data}->{lastBuild}) {
        $logger->info('No lastBuild in ', $d->{build_job}, ' for ', $d->{repo}, ' number ', $d->{pull}->{number});
        $d->{cb}->();
        return;
    }
    
    if ($build_job->{data}->{lastBuild}->{number} >= $d->{build_number}) {
        my ($success, $failure, $need_success) = (0, 0, 0);
        my $failure_url;
        
        my @check = ($d->{build_job});
        while (defined (my $name = shift(@check))) {
            my $job = $d->{job}->{$name};
            unless ($job) {
                $@ = 'job data error';
                $d->{cb}->();
                return;
            }
            $logger->debug('Checking ', $name);
            
            $need_success++;
            unless (defined $job->{build}) {
                # chain not fully built yet
                $logger->debug($name, ' not built yet');
                last;
            }

            # check that job relates to parent job unless its the build job
            unless ($name eq $d->{build_job}) {
                my $cause;
                foreach my $entry (@{$job->{build}->{actions}}) {
                    if (ref($entry) eq 'HASH'
                        and ref($entry->{causes}) eq 'ARRAY')
                    {
                        ($cause) = @{$entry->{causes}};
                        last;
                    }
                }
                
                unless (VerifyCause($cause)) {
                    $@ = 'job data error in cause';
                    $d->{cb}->();
                    return;
                }
                
                $logger->debug('Checking upstream project ', $cause->{upstreamProject}, ' for ', $name);
                
                unless (defined $d->{job}->{$cause->{upstreamProject}}->{data}->{lastBuild}
                    and $cause->{upstreamBuild} == $d->{job}->{$cause->{upstreamProject}}->{data}->{lastBuild}->{number})
                {
                    # child project not triggered yet
                    $logger->debug($name, ' not built yet for upstream project');
                    last;
                }
            }
            
            if (defined $job->{build}->{result}) {
                $logger->debug('Result for ', $name, ' is ', $job->{build}->{result});
                unless ($job->{build}->{result} eq 'SUCCESS') {
                    $failure_url = $job->{build}->{url};
                    $failure = 1;
                    last;
                }
                if (defined $job->{test}) {
                    $logger->debug('Test report for ', $name, ' is ', $job->{test}->{failCount}, ' failed of ', $job->{test}->{totalCount}, ' total');
                    if ($job->{test}->{failCount}) {
                        $failure_url = $job->{build}->{url}.'testReport';
                        $failure = 1;
                        last;
                    }
                }
                $success++;
            }
            
            push(@check, split(/\s*,\s*/o, $job->{childs}));
        }
        
        if ($need_success and $need_success == $success) {
            CheckPullRequest_UpdateStatus2(
                $d,
                'success',
                $build_job->{data}->{lastBuild}->{url}.'downstreambuildview/',
                'Build '.$d->{build_number}.' successful');
            return;
        }
        elsif ($failure) {
            CheckPullRequest_UpdateStatus2(
                $d,
                'failure',
                ($failure_url ? $failure_url : $build_job->{data}->{lastBuild}->{url}.'downstreambuildview/'),
                'Build '.$d->{build_number}.' failed');
            return;
        }
        elsif ($d->{force_status_update}) {
            CheckPullRequest_UpdateStatus2(
                $d,
                'pending',
                $build_job->{data}->{lastBuild}->{url}.'downstreambuildview/',
                'Build '.$d->{build_number}.' pending');
            return;
        }
    }
    
    $logger->info('Waiting for build ', $d->{build_number}, ' for ', $d->{repo}, ' number ', $d->{pull}->{number});
    $d->{cb}->();
}

#
# Do the actual status update
#

sub CheckPullRequest_UpdateStatus2 {
    my ($d, $state, $target_url, $desc) = @_;

    GitHubRequest(
        $d->{status},
        sub {
            if ($@) {
                $@ = 'status update failed: '.$@;
                $d->{cb}->();
                return;
            }
            $logger->info('State ', $state, ' for ', $d->{repo}, ' number ', $d->{pull}->{number});
            $d->{state}->{state} = $state;
            $d->{cb}->();
        },
        method => 'POST',
        body => $JSON->encode({
            state => $state,
            target_url => $target_url,
            description => $desc
        }));
}

#
# Delete the workspace and jobs from Jenkins tied to the pull request
#

sub DeletePullRequest {
    my ($d) = @_;

    unless (exists $CFG{GITHUB_REPO}->{$d->{repo}}) {
        confess 'GITHUB_REPO '.$d->{repo}.' not found';
    }
    unless (exists $CFG{JENKINS_JOBS}->{$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}}) {
        confess 'JENKINS_JOBS '.$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}.' not found';
    }
    my @jobs = @{$CFG{JENKINS_JOBS}->{$CFG{GITHUB_REPO}->{$d->{repo}}->{jobs}}};
    
    $d->{job} = {};
    
    my $code; $code = sub {
        my $job = shift(@jobs);
        unless (defined $job) {
            $d->{cb}->();
            undef $code;
            return;
        }
        my $define = {
            %{$d->{state}->{define}},
            (exists $job->{define} ? (%{$job->{define}}) : ())
        };
        my $name = ResolveDefines($job->{name}, $define);
        
        JenkinsRequest(
            'job/'.$name.'/doWipeOutWorkspace?',
            sub {
                if ($@ =~ /not found/io) {
                    undef $@;
                }
                
                if ($@) {
                    $@ = 'jenkins wipe workspace failed: '.$@;
                    $d->{cb}->();
                    undef $code;
                    return;
                }
                
                $logger->debug('Workspace wiped for ', $name);

                JenkinsRequest(
                    'job/'.$name.'/doDelete?',
                    sub {
                        if ($@ =~ /not found/io) {
                            undef $@;
                        }
                        
                        if ($@) {
                            $@ = 'jenkins delete job failed: '.$@;
                            $d->{cb}->();
                            undef $code;
                            return;
                        }
                        
                        $logger->debug('Job ', $name, ' deleted');
                        $code->();
                    },
                    method => 'POST',
                    no_json => 1);
            },
            method => 'POST',
            no_json => 1);
    };
    $code->();
}

#
# Check Jenkins if pull-clean job is enabled, if not then we disable operations
#

sub CheckJenkins {
    my ($cb) = @_;
    
    JenkinsRequest(
        'job/pull-clean',
        sub {
            my ($job) = @_;
            
            if ($@) {
                $@ = 'jenkins check failed: '.$@;
                $jenkins_enabled = 0;
                $cb->();
                return;
            }

            unless (ref($job) eq 'HASH'
                and defined $job->{buildable})
            {
                $@ = 'jenkins check request invalid';
                $jenkins_enabled = 0;
                $cb->();
                return;
            }
            
            if ($job->{buildable}) {
                $jenkins_enabled = 1;
            }
            else {
                $jenkins_enabled = 0;
            }
            
            $cb->();
        });
}

#
# Get all Jenkins jobs on start that match CLEANUP_JOB_PATTERN and check them
# against GitHub to see if they are closed, if closed set the up to be deleted
#

sub CleanupJobs {
    die "Not implemented";
}

__END__

=head1 NAME

build-bot.pl - Description

=head1 SYNOPSIS

build-bot.pl [options]

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=back

=head1 DESCRIPTION

...

=cut

