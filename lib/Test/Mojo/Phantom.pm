package Test::Mojo::Phantom;

use Mojo::Base -strict;

use Test::More ();
use File::Temp ();
use Mojo::Util;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON 'j';

use constant DEBUG => $ENV{TEST_MOJO_PHANTOM_DEBUG};

sub import {
  my $class = shift;
  Role::Tiny->apply_roles_to_package('Test::Mojo', 'Test::Mojo::Phantom::Role') if $_[0] eq '-apply';
}

sub phantom_raw {
  my $cb = pop;
  my ($js, $read) = @_;

  my $tmp = File::Temp->new(SUFFIX => '.js');
  Mojo::Util::spurt($js => "$tmp");

  my $pid = open my $phantom, '-|', 'phantomjs', "$tmp";
  die 'Could not spawn' unless defined $pid;

  my $stream = Mojo::IOLoop::Stream->new($phantom);
  if ($read) { $stream->on(read => $read) }
  my $id = Mojo::IOLoop->stream($stream);
  $stream->on(close => sub {
    waitpid $pid, 0;
    undef $tmp;
    Mojo::IOLoop->remove($id);
    $cb->(undef);
  });
}

sub phantom {
  my $t = shift;
  my $js = pop;

  my $base = $t->ua->server->nb_url;
  my $url = $t->app->url_for(@_);
  unless ($url->is_abs) {
    $url = $url->to_abs($base);
  }

  my $sep = '--__TEST_MOJO_PHANTOM__--';

  my $lib = '';

  $lib .= sprintf <<'  LIB', $sep;
    // Setup test function
    function test(args) {
      var system = require('system');
      system.stdout.writeLine(JSON.stringify(args));
      system.stdout.writeLine('%s');
      system.stdout.flush();
    }
  LIB

  $lib .= "\n    // Setup Cookies\n";
  foreach my $cookie ($t->ua->cookie_jar->all) {
    my $name = $cookie->name;
    $lib .= sprintf <<'    LIB', $name, $cookie->value, $cookie->domain || $base->host, $name;
      phantom.addCookie({
        name: '%s',
        value: '%s',
        domain: '%s',
      }) || test(['diag', 'Failed to import cookie %s']);
    LIB
  }

  $lib .= sprintf <<'  LIB', $url, $js;
    // Requst page and inject user-provided javascript
    var page = require('webpage').create();
    page.open('%s', function(status) {

      %s;

      phantom.exit();
    });
  LIB

  warn "\nTest::Mojo >>>> Phantom:\n$lib\n" if DEBUG;

  my $buffer = '';
  my $read = sub {
    my ($stream, $bytes) = @_;
    warn "\nTest::Mojo <<<< Phantom: $bytes\n" if DEBUG;
    $buffer .= $bytes;
    while ($buffer =~ s/^(.*)\n$sep\n//) {
      my ($test, @args) = @{ j $1 };
      Test::More->can($test)->(@args);
    }
  };

  Mojo::IOLoop->delay(sub{
    phantom_raw($lib, $read, shift->begin);
  })->wait;
}

package Test::Mojo::Phantom::Role;

use Role::Tiny;
use Test::More ();
use Test::Stream::Toolset;

sub phantom_ok {
  my $t = shift;
  my $opts = ref $_[-1] ? pop : {};
  my $name = $opts->{name} || 'all phantom tests successful';
  my $ctx = Test::Stream::Toolset::context();
  my $st = do {
    $ctx->subtest_start($name);
    my $subtest_ctx = Test::Stream::Toolset::context();
    $subtest_ctx->plan($opts->{plan}) if $opts->{plan};
    Test::Mojo::Phantom::phantom($t, @_);
    $ctx->subtest_stop($name);
  };

  my $e = $ctx->subtest(
    # Stuff from ok (most of this gets initialized inside)
    undef, # real_bool, gets set properly by initializer
    $st->{name}, # name
    undef, # diag
    undef, # bool
    undef, # level

    # Subtest specific stuff
    $st->{state},
    $st->{events},
    $st->{exception},
    $st->{early_return},
    $st->{delayed},
    $st->{instant},
  );

  return $t->success($e->bool);
}

1;
