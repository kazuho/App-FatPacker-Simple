package App::FatPacker::Simple;
use strict;
use warnings;
use utf8;
use App::cpanminus::fatscript;
use Config;
use Cwd 'cwd';
use File::Basename 'basename';
use File::Find 'find';
use File::Spec::Functions 'catdir';
use File::Spec::Unix;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case);
use Perl::Strip;
use Pod::Usage 'pod2usage';

our $VERSION = '0.01';

use parent 'App::FatPacker';

our $IGNORE_FILE = [
    qr/\.pod$/,
    qr/^\.packlist$/,
    qr/^MYMETA\.json$/,
    qr/^install\.json$/,
];

sub new {
    my $class = shift;
    $class->SUPER::new(@_);
}

sub parse_options {
    my $self = shift;
    local @ARGV = @_;
    GetOptions
        "d|dir=s"       => \(my $dir = 'lib,fatlib,local,extlib'),
        "e|exclude=s"   => \(my $exclude),
        "h|help"        => sub { pod2usage(0) },
        "o|output=s"    => \(my $output),
        "q|quiet"       => \(my $quiet),
        "s|strict"      => \(my $strict),
        "v|version"     => sub { printf "%s %s\n", __PACKAGE__, __PACKAGE__->VERSION; exit },
        "color!"        => \(my $color = 1),
        "no-perl-strip" => \(my $no_perl_strip),
    or pod2usage(1);
    $self->{script}     = shift @ARGV or do { warn "Missing scirpt.\n"; pod2usage(1) };
    $self->{dir}        = $self->build_dir($dir);
    $self->{output}     = $output;
    $self->{quiet}      = $quiet;
    $self->{strict}     = $strict;
    $self->{color}      = $color;
    $self->{perl_strip} = $no_perl_strip ? undef : Perl::Strip->new;
    $self->{exclude}    = [];
    if ($exclude) {
        my $cpanm = App::FatPacker::Simple::cpanm->new;
        my $inc = [map {("$_/$Config{archname}", $_)} @{$self->{dir}}];
        for my $e (split /,/, $exclude) {
            my ($metadata, $packlist) = $cpanm->packlists_containing($e, $inc);
            if ($packlist) {
                push @{$self->{exclude}}, $cpanm->unpack_packlist($packlist);
            } else {
                $self->warning("Missing $e in $dir");
            }
        }
    }
    $self;
}

sub warning {
    my ($self, $msg) = @_;
    chomp $msg;
    my $color = $self->{color}
              ? sub { "\e[31m$_[0]\e[m", "\n" }
              : sub { "$_[0]\n" };
    if ($self->{strict}) {
        die $color->("=> ERROR $msg");
    } elsif (!$self->{quiet}) {
        warn $color->("=> WARN $msg");
    }
}

sub debug {
    my ($self, $msg) = @_;
    chomp $msg;
    if (!$self->{quiet}) {
        warn "-> $msg\n";
    }
}

{
    package
        App::FatPacker::Simple::cpanm;
    use parent 'App::cpanminus::script';
    # for relocatable perl patch
    sub unpack_packlist {
        my ($self, $packlist) = @_;
        open my $fh, '<', $packlist or die "$packlist: $!";
        map { chomp; s/\s+relocate_as=.*//; $_ } <$fh>;
    }
}

sub output_filename {
    my $self = shift;
    return $self->{output} if $self->{output};

    my $script = basename $self->{script};
    my ($suffix, @other) = reverse split /\./, $script;
    if (!@other) {
        "$script.fatpack";
    } else {
        unshift @other, "fatpack";
        join ".", reverse(@other), $suffix;
    }
}

sub run {
    my $self = shift;
    my $fatpacked = $self->fatpack_file($self->{script});
    my $output_filename = $self->output_filename;
    open my $fh, ">", $output_filename
        or die "Cannot open '$output_filename': $!\n";
    print {$fh} $fatpacked;
    close $fh;
    my $mode = (stat $self->{script})[2];
    chmod $mode, $output_filename;
    $self->debug("Successfully created $output_filename");
}

sub load_file {
    my ($self, $file, $dir) = @_;

    my $content = do {
        open my $fh, "<", $file or die "Cannot open '$file': $!\n";
        local $/; <$fh>;
    };
    my $relative = File::Spec::Unix->abs2rel($file, $dir);
    my $message  = $self->{perl_strip} ? "perl-strip" : "fatpack";
    $self->debug("$message $relative");
    $self->{perl_strip} ? $self->{perl_strip}->strip($content) : $content;
}

sub collect_files {
    my ($self, $dir, $files) = @_;
    find sub {
        return unless -f $_;
        for my $ignore (@$IGNORE_FILE) {
            $_ =~ $ignore and return;
        }
        if ($File::Find::name =~ m!$dir/$Config{archname}!) {
            return;
        }
        my $relative = File::Spec::Unix->abs2rel($File::Find::name, $dir);
        for my $exclude (@{$self->{exclude}}) {
            if ($File::Find::name eq $exclude) {
                $self->debug("exclude $relative");
                return;
            }
        }
        if (!/\.(?:pm|ix|al)$/) {
            $self->warning("skip non perl module file $relative");
            return;
        }
        $files->{$relative} = $self->load_file($File::Find::name, $dir);
    }, $dir;
}

sub build_dir {
    my ($self, $dir_string) = @_;
    my $cwd = cwd;
    my @dir;
    for my $d (grep -d, map { catdir($cwd, $_) } split /,/, $dir_string) {
        my $try = catdir($d, "lib/perl5");
        if (-d $try) {
            push @dir, $try, catdir($try, $Config{archname});
        } else {
            push @dir, $d, catdir($d, $Config{archname});
        }
    }
    return [ grep -d, @dir ];
}

sub collect_dirs {
    @{ shift->{dir} };
}

1;
__END__

=for stopwords fatpack fatpacks fatpacked deps

=encoding utf-8

=head1 NAME

App::FatPacker::Simple - only fatpack a script

=head1 SYNOPSIS

    > fatpack-simple script.pl

=head1 DESCRIPTION

App::FatPacker::Simple or its frontend C<fatpack-simple> helps you
fatpack a script when B<you> understand the whole dependencies of it.

For tutorial, please look at L<App::FatPacker::Simple::Tutorial>.

=head1 MOTIVATION

App::FatPacker::Simple is a subclass of L<App::FatPacker>.
Let me explain why I wrote this module.

L<App::FatPacker> brings more portability to Perl, that is totally awesome.

As far as I understand, App::FatPacker does 3 things:
(a) trace dependencies for a script,
(b) collects dependencies to C<fatlib> directory
and (c) fatpack the script with modules in C<fatlib>.

As for (a), I often encountered problems. For example,
modules that I don't want to trace trace,
conversely, modules that I DO want to trace do not trace.
Moreover a module changes interfaces recently,
so we have to fatpack that module with new version, etc.
So I think if you author intend to fatpack a script,
B<YOU> need to understand the whole dependencies of it.

As for (b), to locate modules in a directory, why don't you use
C<carton> or C<cpanm>?

So the rest is (c) to fatpack a script with modules in directories,
on which App::FatPacker::Simple concentrates.

That is, App::FatPacker::Simple only fatpacks a script with features:

=over 4

=item automatically perl-strip modules

=item has option to exclude some modules

=back

=head1 SEE ALSO

L<App::FatPacker>

L<App::fatten>

L<Perl::Strip>

=head1 LICENSE

Copyright (C) Shoichi Kaji.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 AUTHOR

Shoichi Kaji E<lt>skaji@cpan.orgE<gt>

=cut

