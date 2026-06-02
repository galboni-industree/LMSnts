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

use JSON::XS ();

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

# In-memory, ephemeral cache. key "1"/"2" -> { title, cover, end }.
my %CACHE;

my $log;

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
	Slim::Formats::RemoteMetadata->registerProvider(
		match => MATCH,
		func  => \&_provider,
	);

	# 3) Register the OPML menu under Radio.
	$class->SUPER::initPlugin(
		tag    => 'ntsradio',
		menu   => 'radios',
		feed   => \&_feed,
		is_app => 0,
		weight => 1,
	);

	# 4) Kick off the poller (first run immediately, then every POLL_SECS).
	_startPoll();

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

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotLive,
		\&_gotError,
		{ timeout => 15 },
	);

	$http->get(API_URL, 'User-Agent' => USER_AGENT);

	# Always reschedule the next cycle, regardless of this request's outcome.
	Slim::Utils::Timers::setTimer(undef, time() + POLL_SECS, \&_poll);
}

sub _gotLive {
	my $http = shift;

	my $data = eval { JSON::XS::decode_json($http->content) };
	if ( $@ || ref $data ne 'HASH' ) {
		$log && $log->debug("failed to parse /live JSON: " . ($@ || 'unexpected structure'));
		return;
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

	# Keep the last known-good cache; the next timer will retry.
	$log && $log->warn('NTS /live request failed: ' . ($error || $http->error || 'unknown error'));
}

# Tell any player currently tuned to this channel to refresh its metadata.
sub _notifyChannel {
	my $ch = shift;

	for my $client ( Slim::Player::Client::clients() ) {
		my $url = _playingUrl($client);
		next unless defined $url && length $url;
		next unless _channel_of($url) eq $ch && $url =~ MATCH;

		Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
		$log && $log->debug('newmetadata -> ' . $client->id . " (ch=$ch)");
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
