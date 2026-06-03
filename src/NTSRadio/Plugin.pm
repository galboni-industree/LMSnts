package Plugins::NTSRadio::Plugin;

# NTS Radio plugin for Lyrion Music Server (LMS).
#
# Exposes the two live NTS channels (NTS 1 / NTS 2) under the Radio menu and
# decorates the Now Playing screen with the currently airing show title and
# artwork, fetched from the public NTS live API. The audio is the plain public
# MP3 stream; the added value is the metadata.
#
# Design (all in this single file):
#   * Menu        -> Slim::Plugin::OPMLBased (two 'audio' items)
#   * Metadata    -> Slim::Formats::RemoteMetadata provider, reads in-memory cache
#   * Poller      -> SimpleAsyncHTTP every POLL_SECS, refreshes the cache and
#                    notifies players whose current show changed.
#
# Hard rules: never block the server thread (all HTTP is async), never crash
# (defensive JSON parsing under eval), exactly one poll timer at a time.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Formats::RemoteMetadata;
use Slim::Control::Request;

use constant API_URL    => 'https://www.nts.live/api/v2/live';
use constant URL_CH1    => 'https://stream-relay-geo.ntslive.net/stream?client=direct';
use constant URL_CH2    => 'https://stream-relay-geo.ntslive.net/stream2?client=direct';
use constant POLL_SECS  => 60;
use constant ICON       => 'plugins/NTSRadio/html/icon.png';
use constant USER_AGENT => 'LMS-NTSRadio/1.0.0 (+https://lyrion.org)';

# URLs handled by the metadata provider. The canonical ntslive.net URLs are
# 302-redirected to radiomast.io edge hosts, so we must match both.
use constant MATCH => qr/(?:ntslive\.net|radiomast\.io)/i;

# JSON decoder, picked once at load time. Prefer JSON::XS (fast, bundled with
# LMS); fall back to core JSON::PP so the plugin works even on a stripped Perl.
my $JSON_DECODE;
BEGIN {
	if ( eval { require JSON::XS; 1 } ) {
		$JSON_DECODE = \&JSON::XS::decode_json;
	} else {
		require JSON::PP;
		$JSON_DECODE = \&JSON::PP::decode_json;
	}
}

# In-memory, ephemeral cache. key "1"/"2" -> { title, cover, end }.
my %CACHE;

my $log;

# Consecutive poll-failure counter, used to keep the log clean: the first
# failure is logged at WARN, the rest at DEBUG, and recovery at INFO.
my $FAIL_STREAK = 0;

# Register the metadata provider only once, even if initPlugin runs again
# (e.g. the user disables then re-enables the plugin without a full restart).
my $PROVIDER_REGISTERED = 0;

sub initPlugin {
	my $class = shift;

	# 1) Register our log category so it shows up in Settings -> Advanced -> Logging.
	Slim::Utils::Log->addLogCategory({
		category     => 'plugin.ntsradio',
		defaultLevel => 'WARN',
		description  => 'PLUGIN_NTSRADIO',
	});
	$log = logger('plugin.ntsradio');

	# 2) Register the Now Playing metadata provider (synchronous, memory-only).
	#    Guarded so a re-init can never stack duplicate providers.
	if ( !$PROVIDER_REGISTERED ) {
		eval {
			Slim::Formats::RemoteMetadata->registerProvider(
				match => MATCH,
				func  => \&_provider,
			);
		};
		if ($@) {
			$log->error("could not register metadata provider: $@");
		} else {
			$PROVIDER_REGISTERED = 1;
		}
	}

	# 3) Register the OPML menu under Radio.
	$class->SUPER::initPlugin(
		tag    => 'ntsradio',
		menu   => 'radios',
		feed   => \&_feed,
		is_app => 0,
		weight => 1,
	);

	# 4) Kick off the poller (first run immediately, then every POLL_SECS).
	#    Wrapped so a transient failure here never aborts plugin load.
	eval { _startPoll(); };
	$log->error("could not start poller: $@") if $@;

	$log->info('NTS Radio plugin initialised');
}

sub shutdownPlugin {
	my $class = shift;

	# Kill the recurring poll timer so we don't leave an orphan behind.
	Slim::Utils::Timers::killTimers(undef, \&_poll);

	$log && $log->info('NTS Radio plugin shut down');
}

# OPMLBased uses this to label/icon the top-level menu node.
sub getDisplayName { 'PLUGIN_NTSRADIO' }

# ---------------------------------------------------------------------------
# Menu feed (synchronous, no network)
# ---------------------------------------------------------------------------

sub _feed {
	my ($client, $callback, $args) = @_;

	my $items = [
		{
			name      => string('PLUGIN_NTSRADIO_CH1'),
			type      => 'audio',
			url       => URL_CH1,
			image     => ICON,
			on_select => 'play',
			play      => URL_CH1,
		},
		{
			name      => string('PLUGIN_NTSRADIO_CH2'),
			type      => 'audio',
			url       => URL_CH2,
			image     => ICON,
			on_select => 'play',
			play      => URL_CH2,
		},
	];

	$callback->({ items => $items });
}

# ---------------------------------------------------------------------------
# Metadata provider (synchronous, reads %CACHE only)
# ---------------------------------------------------------------------------

sub _provider {
	my ($client, $url) = @_;

	my $ch    = _channel_of($url);
	my $label = $ch eq '2' ? 'NTS 2' : 'NTS 1';
	my $entry = $CACHE{$ch} || {};

	my $meta = {
		title   => $entry->{title} || $label,
		artist  => $label,
		album   => 'NTS Radio',
		cover   => $entry->{cover} || ICON,
		icon    => ICON,
		bitrate => 256000,
		type    => 'MP3',
	};

	if ( $log && $log->is_debug ) {
		$log->debug("provider url=$url ch=$ch title=$meta->{title}");
	}

	return $meta;
}

# Detect which channel a (possibly redirected) URL belongs to.
# stream2 / nts2 -> "2"; everything else -> "1".
sub _channel_of {
	my $url = shift || '';

	return '2' if $url =~ /stream2/i || $url =~ /nts2/i;
	return '1';
}

# ---------------------------------------------------------------------------
# Poller
# ---------------------------------------------------------------------------

sub _startPoll {
	Slim::Utils::Timers::killTimers(undef, \&_poll);
	_poll();
}

sub _poll {
	# Idempotent: ensure only one timer is ever scheduled.
	Slim::Utils::Timers::killTimers(undef, \&_poll);

	# Fire the async request. Any failure setting it up is swallowed so the
	# self-healing timer below is ALWAYS rescheduled.
	eval {
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			\&_gotLive,
			\&_gotError,
			{ timeout => 15 },
		);
		$http->get(API_URL, 'User-Agent' => USER_AGENT);
	};
	$log && $@ && $log->warn("poll setup failed: $@");

	# Always reschedule the next cycle, regardless of this request's outcome.
	# Use the same hi-res clock LMS timers run on.
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + POLL_SECS, \&_poll);
}

sub _gotLive {
	my $http = shift;

	my $content = eval { $http->content };
	if ( !defined $content || !length $content ) {
		$log && $log->debug('empty /live response');
		return;
	}

	my $data = eval { $JSON_DECODE->($content) };
	if ( $@ || ref $data ne 'HASH' ) {
		$log && $log->debug("failed to parse /live JSON: " . ($@ || 'unexpected structure'));
		return;
	}

	# Successful fetch+parse: note recovery and reset the failure streak.
	if ($FAIL_STREAK) {
		$log && $log->info("NTS /live recovered after $FAIL_STREAK failed attempt(s)");
		$FAIL_STREAK = 0;
	}

	my $results = $data->{results};
	if ( ref $results ne 'ARRAY' ) {
		$log && $log->debug('no results array in /live response');
		return;
	}

	my @changed;

	for my $r ( @{$results} ) {
		next unless ref $r eq 'HASH';

		my $ch = $r->{channel_name};
		next unless defined $ch && ( $ch eq '1' || $ch eq '2' );

		my $now = $r->{now};
		$now = {} unless ref $now eq 'HASH';

		my $media =
			   ( ref $now->{embeds} eq 'HASH'
			&& ref $now->{embeds}{details} eq 'HASH'
			&& ref $now->{embeds}{details}{media} eq 'HASH' )
			? $now->{embeds}{details}{media}
			: {};

		my $title = $now->{broadcast_title};
		my $cover = $media->{picture_large} // $media->{picture_medium};
		my $end   = $now->{end_timestamp};

		my $prev = $CACHE{$ch} || {};
		if ( ( $prev->{title} // '' ) ne ( $title // '' ) ) {
			push @changed, $ch;
		}

		$CACHE{$ch} = {
			title => $title,
			cover => $cover,
			end   => $end,
		};

		$log && $log->debug("ch=$ch title=" . ($title // '(none)'));
	}

	_notifyChannel($_) for @changed;
}

sub _gotError {
	my ($http, $error) = @_;

	# Keep the last known-good cache; the next timer will retry. To avoid
	# filling server.log when the API is down for a long time, only the first
	# failure of a streak is logged at WARN; the rest go to DEBUG.
	$FAIL_STREAK++;
	my $msg = 'NTS /live request failed: ' . ($error || eval { $http->error } || 'unknown error');

	if ( $FAIL_STREAK == 1 ) {
		$log && $log->warn("$msg (will retry every " . POLL_SECS . 's; further failures at debug)');
	} else {
		$log && $log->debug("$msg (streak=$FAIL_STREAK)");
	}
}

# Tell any player currently tuned to this channel to refresh its metadata.
# Every interaction with player internals is guarded: one odd client must
# never break the loop or take down the server thread.
sub _notifyChannel {
	my $ch = shift;

	my @clients = eval { Slim::Player::Client::clients() };
	return unless @clients;

	for my $client (@clients) {
		next unless $client;

		my $url = _playingUrl($client);
		next unless defined $url && length $url;
		next unless $url =~ MATCH && _channel_of($url) eq $ch;

		eval {
			Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
			$log && $log->debug('newmetadata -> ' . $client->id . " (ch=$ch)");
		};
	}
}

# Best-effort retrieval of the stream URL the client is currently playing.
sub _playingUrl {
	my $client = shift;

	my $song = eval { $client->playingSong };
	return undef unless $song;

	my $url = eval { $song->streamUrl };
	$url  ||= eval { $song->track && $song->track->url };

	return $url;
}

1;
