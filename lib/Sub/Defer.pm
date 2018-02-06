package Sub::Defer;
use strict;
use warnings;
use Exporter qw(import);
use Scalar::Util qw(weaken);
use Carp qw(croak);

our $VERSION = '2.004000';
$VERSION = eval $VERSION;

our @EXPORT = qw(defer_sub undefer_sub undefer_all);
our @EXPORT_OK = qw(undefer_package defer_info);

our %DEFERRED;

sub _getglob { no strict 'refs'; \*{$_[0]} }

BEGIN {
  my $no_subname;
  *_subname
    = defined &Sub::Util::set_subname ? \&Sub::Util::set_subname
    : defined &Sub::Name::subname     ? \&Sub::Name::subname
    : (eval { require Sub::Util } && defined &Sub::Util::set_subname) ? \&Sub::Util::set_subname
    : (eval { require Sub::Name } && defined &Sub::Name::subname    ) ? \&Sub::Name::subname
    : ($no_subname = 1, sub { $_[1] });
  *_CAN_SUBNAME = $no_subname ? sub(){0} : sub(){1};
}

sub _name_coderef {
  shift if @_ > 2; # three args is (target, name, sub)
  _CAN_SUBNAME ? _subname(@_) : $_[1];
}

sub _install_coderef {
  my ($glob, $code) = (_getglob($_[0]), _name_coderef(@_));
  no warnings 'redefine';
  if (*{$glob}{CODE}) {
    *{$glob} = $code;
  }
  # perl will sometimes warn about mismatched prototypes coming from the
  # inheritance cache, so disable them if we aren't redefining a sub
  else {
    no warnings 'prototype';
    *{$glob} = $code;
  }
}

sub undefer_sub {
  my ($deferred) = @_;
  my ($target, $maker, $undeferred_ref) = @{
    $DEFERRED{$deferred}||return $deferred
  };
  return ${$undeferred_ref}
    if ${$undeferred_ref};
  ${$undeferred_ref} = my $made = $maker->();

  # make sure the method slot has not changed since deferral time
  if (defined($target) && $deferred eq *{_getglob($target)}{CODE}||'') {
    no warnings 'redefine';

    # I believe $maker already evals with the right package/name, so that
    # _install_coderef calls are not necessary --ribasushi
    *{_getglob($target)} = $made;
  }
  $DEFERRED{$made} = $DEFERRED{$deferred};
  weaken $DEFERRED{$made}
    unless $target;

  return $made;
}

sub undefer_all {
  undefer_sub($_) for keys %DEFERRED;
  return;
}

sub undefer_package {
  my $package = shift;
  undefer_sub($_)
    for grep {
      my $name = $DEFERRED{$_} && $DEFERRED{$_}[0];
      $name && $name =~ /^${package}::[^:]+$/
    } keys %DEFERRED;
  return;
}

sub defer_info {
  my ($deferred) = @_;
  my $info = $DEFERRED{$deferred||''} or return undef;

  my ($target, $maker, $options, $undeferred_ref, $deferred_sub) = @$info;
  [
    $target, $maker, $options,
    ( $undeferred_ref && $$undeferred_ref ? $$undeferred_ref : ()),
  ];
}

sub defer_sub {
  my ($target, $maker, $options) = @_;
  my $package;
  my $subname;
  ($package, $subname) = $target =~ /^(.*)::([^:]+)$/
    or croak "$target is not a fully qualified sub name!"
    if $target;
  $package ||= $options && $options->{package} || caller;
  my @attributes = @{$options && $options->{attributes} || []};
  if (@attributes) {
    /\A\w+(?:\(.*\))?\z/s || croak "invalid attribute $_"
      for @attributes;
  }
  my $deferred;
  my $undeferred;
  my $deferred_info = [ $target, $maker, $options, \$undeferred ];
  if (@attributes || $target && !_CAN_SUBNAME) {
    my $code
      =  q[#line ].(__LINE__+2).q[ "].__FILE__.qq["\n]
      . qq[package $package;\n]
      . ($target ? "sub $subname" : '+sub') . join('', map " :$_", @attributes)
      . q[ {
        package Sub::Defer;
        # uncoverable subroutine
        # uncoverable statement
        $undeferred ||= undefer_sub($deferred_info->[4]);
        goto &$undeferred; # uncoverable statement
        $undeferred; # fake lvalue return
      }]."\n"
      . ($target ? "\\&$subname" : '');
    my $e;
    $deferred = do {
      no warnings qw(redefine closure);
      local $@;
      eval $code or $e = $@; # uncoverable branch true
    };
    die $e if defined $e; # uncoverable branch true
  }
  else {
    # duplicated from above
    $deferred = sub {
      $undeferred ||= undefer_sub($deferred_info->[4]);
      goto &$undeferred;
    };
    _install_coderef($target, $deferred)
      if $target;
  }
  weaken($deferred_info->[4] = $deferred);
  weaken($DEFERRED{$deferred} = $deferred_info);
  return $deferred;
}

sub CLONE {
  %DEFERRED = map { defined $_ && $_->[4] ? ($_->[4] => $_) : () } values %DEFERRED;
  foreach my $info (values %DEFERRED) {
    weaken($info)
      unless $info->[0] && ${$info->[3]};
  }
}

1;
__END__

=head1 NAME

Sub::Defer - Defer generation of subroutines until they are first called

=head1 SYNOPSIS

 use Sub::Defer;

 my $deferred = defer_sub 'Logger::time_since_first_log' => sub {
    my $t = time;
    sub { time - $t };
 };

  Logger->time_since_first_log; # returns 0 and replaces itself
  Logger->time_since_first_log; # returns time - $t

=head1 DESCRIPTION

These subroutines provide the user with a convenient way to defer creation of
subroutines and methods until they are first called.

=head1 SUBROUTINES

=head2 defer_sub

 my $coderef = defer_sub $name => sub { ... }, \%options;

This subroutine returns a coderef that encapsulates the provided sub - when
it is first called, the provided sub is called and is -itself- expected to
return a subroutine which will be goto'ed to on subsequent calls.

If a name is provided, this also installs the sub as that name - and when
the subroutine is undeferred will re-install the final version for speed.

Exported by default.

=head3 Options

A hashref of options can optionally be specified.

=over 4

=item package

The package to generate the sub in.  Will be overridden by a fully qualified
C<$name> option.  If not specified, will default to the caller's package.

=item attributes

The L<perlsub/Subroutine Attributes> to apply to the sub generated.  Should be
specified as an array reference.

=back

=head2 undefer_sub

 my $coderef = undefer_sub \&Foo::name;

If the passed coderef has been L<deferred|/defer_sub> this will "undefer" it.
If the passed coderef has not been deferred, this will just return it.

If this is confusing, take a look at the example in the L</SYNOPSIS>.

Exported by default.

=head2 defer_info

 my $data = defer_info $sub;
 my ($name, $generator, $options, $undeferred_sub) = @$data;

Returns original arguments to defer_sub, plus the undeferred version if this
sub has already been undeferred.

Note that $sub can be either the original deferred version or the undeferred
version for convenience.

Not exported by default.

=head2 undefer_all

 undefer_all();

This will undefer all deferred subs in one go.  This can be very useful in a
forking environment where child processes would each have to undefer the same
subs.  By calling this just before you start forking children you can undefer
all currently deferred subs in the parent so that the children do not have to
do it.  Note this may bake the behavior of some subs that were intended to
calculate their behavior later, so it shouldn't be used midway through a
module load or class definition.

Exported by default.

=head2 undefer_package

  undefer_package($package);

This undefers all deferred subs in a package.

Not exported by default.

=head1 SUPPORT

See L<Sub::Quote> for support and contact information.

=head1 AUTHORS

See L<Sub::Quote> for authors.

=head1 COPYRIGHT AND LICENSE

See L<Sub::Quote> for the copyright and license.

=cut
