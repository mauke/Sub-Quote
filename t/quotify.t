use strict;
use warnings;
no warnings 'once';
use Test::More;
use Data::Dumper;
use B;

use Sub::Quote qw(
  quotify
);

use constant HAVE_UTF8 => Sub::Quote::_HAVE_IS_UTF8;
use constant INF => 9**9**9;
use constant NAN => sin(INF);
use constant INF_NAN_SUPPORT => (
  INF == 10 * INF
  and !(NAN == 0 || NAN == 0.1 || NAN + 0 == 0)
);

sub _dump {
  my $value = shift;
  if (!defined $value) {
    return 'undef';
  }
  elsif (is_strict_numeric($value)) {
    return "$value";
  }
  local $Data::Dumper::Terse = 1;
  local $Data::Dumper::Useqq = 1;
  my $d = Data::Dumper::Dumper("$value");
  $d =~ s/\s+$//;
  $d;
}

sub is_numeric {
  my $flags = B::svref_2object(\($_[0]))->FLAGS;
  !!( $flags & ( B::SVp_IOK | B::SVp_NOK ) )
}

sub is_float {
  my $num = shift;
    $num != int($num)
  || $num > ~0
  || $num < -(~0>>1)-1;
}

sub is_strict_numeric {
  my $flags = B::svref_2object(\($_[0]))->FLAGS;

  !!( $flags & ( B::SVp_IOK | B::SVp_NOK ) && !( $flags & B::SVp_POK ) )
}

my %flags;
{
  no strict 'refs';
  for my $flag (qw(
    SVs_TEMP
    SVs_OBJECT
    SVs_GMG
    SVs_SMG
    SVs_RMG
    SVf_IOK
    SVf_NOK
    SVf_POK
    SVf_OOK
    SVf_FAKE
    SVf_READONLY
    SVf_PROTECT
    SVf_BREAK
    SVp_IOK
    SVp_NOK
    SVp_POK
  )) {
    if (defined &{'B::'.$flag}) {
      $flags{$flag} = &{'B::'.$flag};
    }
  }
}
sub flags {
  my $flags = B::svref_2object(\($_[0]))->FLAGS;
  join ' ', sort grep $flags & $flags{$_}, keys %flags;
}

# unique values taking flags into account
sub _uniq {
  my %s;
  grep {
    my $copy = $_;
    my $key = defined $_ ? flags($_).'|'.(HAVE_UTF8 && utf8::is_utf8($_) ? 1 : 0)."|$copy" : '';
    !$s{$key}++;
  } @_;
}

sub eval_utf8 {
  my $value = shift;
  my $output;
  eval "use utf8; \$output = $value; 1;" or die $@;
  $output;
}

my @numbers = (
  -20 .. 20,
  qw(00 01 .0 .1 0.0 0.00 00.00 0.10 0.101),
  '0 but true',
  '0e0',
  (map +("1e$_", "-1e$_"), -50, -5, 0, 1, 5, 50),
  (map 1 / $_, -10 .. -2, 2 .. 10),
  (INF_NAN_SUPPORT ? ( INF, -(INF), NAN, -(NAN) ) : ()),
);

my @strings = (
  "",
  (map +chr($_), 0 .. 0xff),
  "\\a\"",
  "\xC3\x84",
  "\x{ABCD}",
  "\x{1F4A9}",
);

if (HAVE_UTF8) {
  utf8::downgrade($_, 1)
    for @strings;
}

my @utf8_strings;
if (HAVE_UTF8) {
  @utf8_strings = @strings;
  utf8::upgrade($_)
    for @utf8_strings;
}

my @booleans = (!1, !0);

my @quotify = (
  undef,
  @booleans,
  (map {
    my $indeterminate = $_;
    my $number = $indeterminate + 0;
    my $string = $indeterminate . "";
    ($number, $indeterminate, $string);
  } @numbers),
  @strings,
  @utf8_strings,
);

# HAVE_UTF8 will be artificially false under quotify-5.6.t.  skip utf8 strings
# in this case as they will produce warnings or errors in newer perls.
@quotify = grep !utf8::is_utf8($_), @quotify
  if !HAVE_UTF8 and "$]" >= 5.025;

my $eval_utf8;

for my $value (_uniq @quotify) {
  my $value_name
    = _dump($value)
    . (HAVE_UTF8 && utf8::is_utf8($value) ? ' utf8' : '')
    . (is_strict_numeric($value) ? ' pure' : '')
    . (is_numeric($value) ? ' num' : '');

  my $quoted = quotify(my $copy = $value);
  utf8::downgrade($quoted, 1)
    if HAVE_UTF8;

  my $note = "quotified as $quoted";
  utf8::encode($note)
    if defined &utf8::encode;
  note $note;

  is flags($copy), flags($value),
    "$value_name: quotify doesn't modify input";

  my $evaled;
  eval "\$evaled = $quoted; 1" or die $@;

  for my $check (
    [ $evaled ],
    ( HAVE_UTF8 ? [ eval_utf8($quoted), ' under utf8' ] : ()),
  ) {
    my ($check_value, $suffix) = @$check;
    $suffix ||= '';

    if (is_strict_numeric($value)) {
      ok is_strict_numeric($check_value),
        "$value_name: numeric status maintained$suffix";
    }

    if (is_numeric($value)) {
      if ($value == $value) {
        my $todo;
        if ($check_value != $value && is_float($value)) {
          my $diff = abs($check_value - $value);
          my $accuracy = abs($value)/$diff;
          my $precision = Sub::Quote::_MAX_FLOAT_PRECISION - 1;
          $todo = "not always accurate beyond $precision digits"
            if $accuracy <= 10**$precision;
        }

        local $TODO = $todo
          if $todo;
        cmp_ok $check_value, '==', $value,
          "$value_name: numeric value maintained$suffix"
          or do {
            diag "quotified as $quoted";
            diag "got float      : ".uc unpack("h*", pack("F", $check_value));
            diag "expected float : ".uc unpack("h*", pack("F", $value));
          };
      }
      else {
        cmp_ok $check_value, '!=', $check_value,
          "$value_name: numeric value maintained$suffix";
      }
    }

    if (defined $value) {
      cmp_ok $check_value, 'eq', $value,
        "$value_name: string value maintained$suffix";
    }
    else {
      is $check_value, undef,
        "$value_name: undef maintained$suffix";
    }
  }
}

done_testing;
