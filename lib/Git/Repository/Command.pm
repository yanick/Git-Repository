package Git::Repository::Command;

use strict;
use warnings;
use 5.006;

use Carp;
use Cwd qw( cwd );
use IO::Handle;
use IPC::Open3 qw( open3 );
use Scalar::Util qw( blessed );
use File::Spec;
use Config;
use System::Command;

our $VERSION = '1.12';
our @ISA = qw( System::Command );


# a few simple accessors
for my $attr (qw( pid stdin stdout stderr exit signal core )) {
    no strict 'refs';
    *$attr = sub { return $_[0]{$attr} };
}
for my $attr (qw( cmdline )) {
    no strict 'refs';
    *$attr = sub { return @{ $_[0]{$attr} } };
}

# CAN I HAS GIT?
my %binary;    # cache calls to _is_git
sub _is_git {
    my ($binary) = @_;

    # compute cache key:
    # - filename (path):     path
    # - absolute path (abs): empty string
    # - relative path (rel): dirname
    my $path = defined $ENV{PATH} && length( $ENV{PATH} ) ? $ENV{PATH} : '';
    my ( $type, $key )
        = ( File::Spec->splitpath($binary) )[2] eq $binary ? ( 'path', $path )
        : File::Spec->file_name_is_absolute($binary)       ? ( 'abs', '' )
        :                                                    ( 'rel', cwd() );

    # This relatively complex cache key scheme allows PATH or cwd to change
    # during the life of a program using Git::Repository, which is likely
    # to happen. On the other hand, it completely ignores the possibility
    # that any part of the cached path to a git binary could be a symlink
    # which target may also change during the life of the program.

    # check the cache
    return $binary{$type}{$key}{$binary}
        if exists $binary{$type}{$key}{$binary};

    # compute a list of candidate files (look in PATH if needed)
    my $git;
    if ( $type eq 'path' ) {
        my $path_sep = $Config::Config{path_sep} || ';';
        my @ext = (
            '', $^O eq 'MSWin32' ? ( split /\Q$path_sep\E/, $ENV{PATHEXT} ) : ()
        );
        ($git) = grep {-e}
            map {
            my $path = $_;
            map { File::Spec->catfile( $path, $_ ) } map {"$binary$_"} @ext
            }
            split /\Q$path_sep\E/, $path;
    }
    else {
        $git = File::Spec->rel2abs($binary);
    }

    # if we can't find any, we're done
    return $binary{$type}{$key}{$binary} = undef
        if !( defined $git && -x $git );

    # try to run it
    my ( $pid, $in, $out, $err ) = __PACKAGE__->spawn( $git, '--version' );
    my $version = <$out>;

    # does it really look like git?
    return $binary{$type}{$key}{$binary}
        = $version =~ /^git version \d/
            ? $type eq 'path'
                ? $binary    # leave the shell figure it out itself too
                : $git
            : undef;
}

sub new {
    my ( $class, @cmd ) = @_;

    # split the args
    my ($r) = grep { blessed $_ && $_->isa('Git::Repository') } @cmd;
    my @o = grep { ref eq 'HASH' } @cmd;
    @cmd = grep { !ref } @cmd;

    # keep changes to the environment local
    local %ENV = %ENV;

    # a Git::Repository object will give more context
    if ($r) {

        # pick up repository options
        unshift @o, $r->options;

        # get some useful paths
        my ( $git_dir, $work_tree ) = ( $r->git_dir, $r->work_tree );
        unshift @o, { cwd => $work_tree }
            if defined $work_tree && length $work_tree;

        # setup our %ENV
        delete @ENV{qw( GIT_DIR GIT_WORK_TREE )};
        $ENV{GIT_DIR}       = $git_dir;
        $ENV{GIT_WORK_TREE} = $work_tree
            if defined $work_tree;
    }

    # get and check the git command
    my $git_cmd = ( map { exists $_->{git} ? $_->{git} : () } @o )[-1];
    $git_cmd = 'git' if !defined $git_cmd;
    my $git = _is_git($git_cmd);

    croak "git binary '$git_cmd' not available or broken"
        if !defined $git;

    # turn us into a dumb terminal
    delete $ENV{TERM};

    # spawn the command and re-bless the object in our class
    return bless System::Command->new( $git, @cmd, @o ), $class;
}

1;

__END__

=head1 NAME

Git::Repository::Command - Command objects for running git

=head1 SYNOPSIS

    use Git::Repository::Command;

    # invoke an external git command, and return an object
    $cmd = Git::Repository::Command->new(@cmd);

    # a Git::Repository object can provide more context
    $cmd = Git::Repository::Command->new( $r, @cmd );

    # options can be passed as a hashref
    $cmd = Git::Repository::Command->new( $r, @cmd, \%option );

    # $cmd is basically a hash, with keys / accessors
    $cmd->stdin();     # filehandle to the process' stdin (write)
    $cmd->stdout();    # filehandle to the process' stdout (read)
    $cmd->stderr();    # filehandle to the process' stdout (read)
    $cmd->pid();       # pid of the child process

    # done!
    $cmd->close();

    # exit information
    $cmd->exit();      # exit status
    $cmd->signal();    # signal
    $cmd->core();      # core dumped? (boolean)

    # cut to the chase
    my ( $pid, $in, $out, $err ) = Git::Repository::Command->spawn(@cmd);


=head1 DESCRIPTION

C<Git::Repository::Command> is a class that actually launches a B<git>
commands, allowing to interact with it through its C<STDIN>, C<STDOUT>
and C<STDERR>.

This class is a subclass of C<System::Command>, meant to be invoked
through C<Git::Repository>.

=head1 METHODS

As a subclass of C<System::Command>,
C<Git::Repository::Command> supports the following methods:

=head2 new( @cmd )

Runs a B<git> command with the parameters in C<@cmd>.

If C<@cmd> contains a C<Git::Repository> object, it is used to provide
context to the B<git> command.

If C<@cmd> contains one or more hash reference, they are taken as
I<option> hashes. The recognized keys are:

=over 4

=item C<git>

The actual git binary to run. By default, it is just C<git>.

=item C<cwd>

The I<current working directory> in which the git command will be run.

=item C<env>

A hashref containing key / values to add to the git command environment.

=item C<input>

A string that is send to the git command standard input, which is then closed.

Using the empty string as C<input> will close the git command standard input
without writing to it.

Using C<undef> as C<input> will not do anything. This behaviour provides
a way to modify options inherited from C<new()> or a hash populated by
some other part of the program.

On some systems, some git commands may close standard input on startup,
which will cause a SIGPIPE when trying to write to it. This will raise
an exception.

=back

If the C<Git::Repository> object has its own option hash, it will be used
to provide default values that can be overriden by the actual option hash
passed to C<new()>.

If several option hashes are passed to C<new()>, they will all be merged,
keys in later hashes taking precedence over keys in earlier hashes.

The C<Git::Repository::Command> object returned by C<new()> has a
number of attributes defined (see below).


=head2 close()

Close all pipes to the child process, and collects exit status, etc.
and defines a number of attributes (see below).

=head2 Accessors

The attributes of a C<Git::Repository::Command> object are also accessible
through a number of accessors.

The object returned by C<new()> will have the following attributes defined:

=over 4

=item cmdline()

Return the command-line actually executed, as a list of strings.

=item pid()

The PID of the underlying B<git> command.

=item stdin()

A filehandle opened in write mode to the child process' standard input.

=item stdout()

A filehandle opened in read mode to the child process' standard output.

=item stderr()

A filehandle opened in read mode to the child process' standard error output.

=back

Regarding the handles to the child git process, note that in the
following code:

    my $fh = Git::Repository::Command->new( @cmd )->stdout;

C<$fh> is opened and points to the output of the git subcommand, while
the anonymous C<Git::Repository::Command> object has been destroyed.
Once C<$fh> is destroyed, the subprocess will be reaped, thus avoiding
zombies.

After the call to C<close()>, the following attributes will be defined:

=over 4

=item exit()

The exit status of the underlying B<git> command.

=item core()

A boolean value indicating if the command dumped core.

=item signal()

The signal, if any, that killed the command.

=back

=head1 AUTHOR

Philippe Bruhat (BooK), C<< <book at cpan.org> >>

=head1 ACKNOWLEDGEMENTS

The core of C<Git::Repository::Command> has been moved into its own
distribution: C<System::Command>. Proper Win32 support is now delegated
to that module.

Before that, the Win32 implementation owed a lot to two people.
First, Olivier Raginel (BABAR), who provided me with a test platform
with Git and Strawberry Perl installed, which I could use at any time.
Many thanks go also to Chris Williams (BINGOS) for pointing me towards
perlmonks posts by ikegami that contained crucial elements to a working
MSWin32 implementation.

=head1 COPYRIGHT

Copyright 2010-2011 Philippe Bruhat (BooK), all rights reserved.

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

