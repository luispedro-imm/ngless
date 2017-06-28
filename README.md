# NGLess: NGS Processing with Less Work

[![Join the chat at https://gitter.im/luispedro/ngless](https://badges.gitter.im/Join%20Chat.svg)](https://gitter.im/luispedro/ngless?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

[![Build Status](https://travis-ci.org/luispedro/ngless.svg?branch=master)](https://travis-ci.org/luispedro/ngless)

Ngless is a domain-specific language for NGS (next-generation sequencing data)
processing.

**Note**: This is *pre-release* software, currently available as a preview
only. Please [get in touch](mailto:coelho@embl.de) if you want to use it in
your work. For questions, you can also use the [ngless mailing
list](https://groups.google.com/forum/#!forum/ngless).

## Example

    ngless "0.0"
    input = fastq(['ctrl1.fq','ctrl2.fq','stim1.fq','stim2.fq'])
    preprocess(input) using |read|:
        read = read[5:]
        read = substrim(read, min_quality=26)
        if len(read) < 31:
            discard

    mapped = map(input,
                    reference='hg19')
    write(count(mapped, features=['gene']),
            ofile='gene_counts.csv',
            format={csv})

## Installing

Ngless can be esily obtained in binary form for Linux/Windows (experimental)
and with either *brew* or *nix* (for Mac OS X or Linux). Of course, you can
also compile from source.

Until an official release, the binary versions are not updated regularly.
Naturally, once an official version 1.0 is released, we will have official
versions for all these channels.

### Linux

You can get an [unreleased statically linked version of
NGless](http://vm-lux.embl.de/~coelho/ngless-data/releases/ngless-0.0.0-unreleased-Linux64) or a [nighly build of the latest development code](https://gitlab.com/ngless/ngless/builds/artifacts/master/raw/bin/ngless?job=build-and-test-ubuntu).
This should work across a wide range of Linux versions (please
[report](https://github.com/luispedro/ngless/issues) any issues you encounter):

    wget http://vm-lux.embl.de/~coelho/ngless-data/releases/ngless-0.0.0-unreleased-Linux64
    chmod +x ngless-0.0.0-unreleased-Linux64
    ./ngless-0.0.0-unreleased-Linux64

This download bundles bwa, samtools and megahit (also statically linked).

If you want to try one of ngless' builtin modules (motus, specI, ...) you can download [the full nighly build zip file](https://gitlab.com/ngless/ngless/builds/artifacts/master/download?job=build-and-test-ubuntu) which includes them.

### Brew

If you use [homebrew](http://brew.sh/), you easily build and install
[ngless](http://ngless.readthedocs.io/) using this repository.

First install the two required dependencies:

    brew install homebrew/science/bwa
    brew install homebrew/science/samtools


Now install ngless:

    brew tap luispedro/ngless
    brew install ngless

This should download the brew formula and build ngless.

This has been tested to work on both Mac OS X and Linux (using
[linuxbrew](http://linuxbrew.sh/)).

### Nix

If you use [nix](http://nixos.org), you can easily build and install ngless
using it (these scripts also install all necessary dependencies):

    nix-env -i -f https://github.com/luispedro/ngless-nix/archive/master.tar.gz

This should download the nix scripts and build ngless.

If you prefer, you can also first clone the repository:

    git clone https://github.com/luispedro/ngless-nix
    cd ngless-nix
    # inspect the default.nix & ngless.nix files if you wish
    nix-env -i -f .


### Windows

Download and run the [Windows
Installer](https://dl.dropboxusercontent.com/u/68453937/NGLess-0.0.0-install.exe).
The result is a command line utility, so you need to run it on the command
line (running `ngless` should work after running the installer, although you
may have to start a new CMD terminal.

The Windows package includes bwa and samtools. The bwa and samtools executables
are available as `ngless-0.0.0-bwa` and `ngless-0.0.0-samtools`, respectively.
It has been tested on Windows 10, but this has not had as intensitive testing
as the Linux/Mac OS X versions so any [bug
reports](https://github.com/luispedro/ngless/issues) are appreciated.

### From Source

Installing/compiling from source is also possible. Clone
[http://github.com/luispedro/ngless](http://github.com/luispedro/ngless)

#### Dependencies

[stack](http://docs.haskellstack.org/en/stable/README/) is highly recommended.
Install it and running `make` should (1) download all dependencies with the
correct versions and (2) build ngless. It will perform this task in its own
sandbox so it will not interfere with any other work.

You should also have `gcc` installed (or another C-compiler).

The following sequence of commands should download and build the software

    git clone https://github.com/luispedro/ngless
    cd ngless
    make

To install, you can use the following command (replace `<PREFIX>` with
the directory where you wish to install, default is `/usr/local`):

    make install prefix=<PREFIX>

## More information

- [Full documentation](http://ngless.readthedocs.org/en/latest/)
- [Frequently Asked Questions (FAQ)](http://ngless.readthedocs.org/en/latest/faq.html)
- [ngless webpage](http://luispedro.github.io/ngless/)
- [ngless mailing list](https://groups.google.com/forum/#!forum/ngless)

## Authors

- [Luis Pedro Coelho](http://luispedro.org) (email: [coelho@embl.de](mailto:coelho@embl.de)) (on twitter: [@luispedrocoelho](https://twitter.com/luispedrocoelho))
- Paulo Monteiro
- [Ana Teresa Freitas](http://web.tecnico.ulisboa.pt/ana.freitas/)

