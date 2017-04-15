use strict;
use warnings;
no warnings 'once';
use Test::More;
use Test::Fatal;
use Data::Dumper;
use B;

use constant HAVE_UTF8 => defined &utf8::upgrade && defined &utf8::is_utf8;;

use Sub::Quote qw(
  quotify
);

sub _dump {
  my $value = shift;
  local $Data::Dumper::Terse = 1;
  local $Data::Dumper::Useqq = 1;
  my $d = Data::Dumper::Dumper($value);
  $d =~ s/\s+$//;
  $d;
}

sub is_numeric {
  my $val = shift;
  my $sv = B::svref_2object(\$val);
  !!($sv->FLAGS & ( B::SVp_IOK | B::SVp_NOK ) )
}

BEGIN {
  if (HAVE_UTF8) {
    eval '
      sub eval_utf8 {
        my $value = shift;
        my $output;
        eval "use utf8; \$output = $value; 1;" or die $@;
        $output;
      }
      1;
    ' or die $@;
  }
}

my @numbers = (
  -20 .. 20,
  (map 1 / $_, -10 .. -2, 2 .. 10),
);

my @strings = (
  "\x00",
  "a",
  "\xC3\x84",
  "\xE8",
  "\xFC",
  "\xFF",
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

my @quotify = (
  undef,
  (map {
    my $used_as_string = $_;
    my $string = "$used_as_string";
    ($_, $used_as_string, $string);
  } @numbers),
  @strings,
  @utf8_strings,
);

my $eval_utf8;

for my $value (@quotify) {
  my $copy1 = my $copy2 = my $copy3 = my $copy4 = $value;
  my $value_name
    = _dump($value)
    . (HAVE_UTF8 && utf8::is_utf8($value) ? ' utf8' : '')
    . (is_numeric($value) ? ' num' : '');

  my $quoted = quotify $copy1;

  is B::svref_2object(\$copy1)->FLAGS, B::svref_2object(\$copy2)->FLAGS,
    "$value_name: quotify doesn't modify input";

  my $evaled;
  eval "\$evaled = $quoted; 1" or die $@;

  is is_numeric($evaled), is_numeric($value),
    "$value_name: numeric status maintained";

  is $copy3, $evaled,
    "$value_name: value maintained";

  if (HAVE_UTF8) {
    my $utf8_evaled = eval_utf8($quoted);

    is is_numeric($value), is_numeric($evaled),
      "$value_name: numeric status maintained under utf8";

    is $copy4, $utf8_evaled,
      "$value_name: value maintained under utf8";
  }
}

done_testing;
