====================
What's New (History)
====================

Development version
-------------------

Bugfixes
~~~~~~~~
- Fixed bug where header was printed even when STDOUT was used
- Fix to lock1's return value when used with paths (#68 - reopen)
- Support _F/_R suffixes for forward/reverse in load_mocat_sample
- Fixed bug where writing interleaved FastQ to STDOUT did not work as expected
- Fix saving fastq sets with --subsample (issue #85)
- Fix (hypothetical) case where the two mate files have different FastQ encodings

User-visible improvements
~~~~~~~~~~~~~~~~~~~~~~~~~

- samtools_sort() now accepts by={name} to sort by read name
- arg1 in external modules is no longer always treated as a path
- Added expand_searchdir to external modules API (closes #56)
- Add __extra_megahit_args to assemble() (issue #86)
- Better error messages when version is mis-specified
- Support `NO_COLOR <https://no-color.org/>`__ standard: when ``NO_COLOR`` is
  present in the environment, print no colours.


Internal improvements
~~~~~~~~~~~~~~~~~~~~~

- NGLess now pre-emptively garbage collects files when they are no longer needed (issue #79)

Version 0.9.1
-----------

Released July 17th 2018

- Added `NGLess preprint citation
  <https://www.biorxiv.org/content/early/2018/07/13/367755>`__

Version 0.9
-----------

Released July 12th 2018

User-visible improvements
~~~~~~~~~~~~~~~~~~~~~~~~~

- Added ``allbest()`` method to MappedRead.
- NGLess will issue a warning before overwriting an existing file.
- Output directory contains PNG files with basic QC stats
- Added modules for gut gene catalogs of `mouse <https://www.nature.com/articles/nbt.3353>`__, `pig <https://www.nature.com/articles/nmicrobiol2016161>`__, and `dog <https://microbiomejournal.biomedcentral.com/articles/10.1186/s40168-018-0450-3>`__
- Updated the `integrated gene catalog <https://www.nature.com/articles/nbt.2942>`__

Internal improvements
~~~~~~~~~~~~~~~~~~~~~

- All lock files now are continuously "touched" (i.e., their modification time
  is updated every 10 minutes). This makes it easier to discover stale lock
  files.
- The automated downloading of builtin references now uses versioned URLs, so
  that, in the future, we can change them without breaking backwards
  compatibility.

Version 0.8.1
-------------

Released June 5th 2018

This is a minor release and upgrading is recommended.

Bugfixes
~~~~~~~~

- Fix for systems with non-working locale installations
- Much faster `collect <Functions.html#count>`__ calls
- Fixed `lock1
  <http://ngless.embl.de/stdlib.html?highlight=lock1#parallel-module>`__ when
  used with full paths (see `issue #68 <https://github.com/ngless-toolkit/ngless/issues/68>`__)
- Fix expansion of searchpath with external modules (see `issue #56
  <https://github.com/ngless-toolkit/ngless/issues/56>`__)

Version 0.8
-----------

Released May 6th 2018

Incompatible changes
~~~~~~~~~~~~~~~~~~~~

- Added an extra field to the FastQ statistics, with the fraction of basepairs
  that are not ATCG. This means that uses of `qcstats
  <Functions.hml#qcstats>`__ must use an up-to-date version declaration.

- In certain cases (see below), the output of count when using a GFF will change.

User-visible improvements
~~~~~~~~~~~~~~~~~~~~~~~~~

- Better handling of multiple features in a GFF. For example, using a GFF
  containing "gene_name=nameA,nameB" would result in::

      nameA,nameB    1

    Now the same results in::

      nameA          1
      nameB          1

  This follows after `https://git.io/vpagq <https://git.io/vpagq>`__ and the
  case of *Parent=AF2312,AB2812,abc-3*

- Support for `minimap2 <https://github.com/lh3/minimap2>`__ as alternative
  mapper. Import the ``minimap2`` module and specify the ``mapper`` when
  calling `map <Functions.html#map>`__. For example::

    ngless '0.8'
    import "minimap2" version "1.0"

    input = paired('sample.1.fq', 'sample.2.fq', singles='sample.singles.fq')
    mapped = map(input, fafile='ref.fna', mapper='minimap2')
    write(mapped, ofile='output.sam')

- Added the ``</>`` operator. This can be used to concatenate filepaths. ``p0
  </> p1`` is short for ``p0 + "/" + p1`` (except that it avoids double forward
  slashes).

- Fixed a bug in `select <Functions.html#select>`__ where in some edge cases,
  the sequence would be incorrectly omitted from the result. Given that this is
  a rare case, if a version prior to 0.8 is specified in the version header,
  the old behaviour is emulated.

- Added bzip2 support to `write <Functions.html#write>`__.

- Added reference argument to `count <Functions.html#count>`__.

Bug fixes
~~~~~~~~~

- Fix writing multiple compressed Fastq outputs.

- Fix corner case in `select <Functions.html#select>__`. Previously, it was
  possible that some sequences were wrongly removed from the output.

Internal improvements
~~~~~~~~~~~~~~~~~~~~~

- Faster `collect() <Functions.html#collect>`__
- Faster FastQ processing
- Updated to bwa 0.7.17
- External modules now call their init functions with a lock
- Updated library collection to LTS-11.7

Version 0.7.1
-------------

Released Mar 17 2018

Improves memory usage in ``count()`` and the use the ``when-true`` flag in
external modules.

Version 0.7
-----------

Released Mar 7 2018

New functionality in NGLess language
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


- Added `max_trim <methods.html>`__ argument to ``filter`` method of
  ``MappedReadSet``.
- Support saving compressed SAM files
- Support for saving interleaved FastQ files
- Compute number Basepairs in FastQ stats
- Add ``headers`` argument to `samfile function <Functions.html#samfile>`__

Bug fixes
~~~~~~~~~

- Fix ``count``'s mode ``{intersection_strict}`` to no longer behave as ``{union}``
- Fix ``as_reads()`` for single-end reads
- Fix ``select()`` corner case

In addition, this release also improves both speed and memory usage.


Version 0.6
-----------

Released Nov 29 2017

Behavioural changes
~~~~~~~~~~~~~~~~~~~


- Changed ``include_m1`` default in `count() <Functions.html#count>`__ function
  to True

New functionality in NGLess language
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- Added `orf_find <Functions.html#orf_find>`__ function (implemented through
  Prodigal) for open reading frame (ORF) predition

- Add `qcstats() <Functions.html#qcstats>`__ function to retrieve the computed
  QC stats.

- Added reference alias for a more human readable name
- Updated builtin referenced to include latest releases of assemblies

New functionality in NGLess tools
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- Add --index-path functionality to define where to write indices.

- Allow `citations` as key in external modules (generally better citations
  information)

- Use multiple threads in SAM->BAM conversion

- Better error checking/script validation

Bug fixes
~~~~~~~~~

- Output preprocessed FQ statistics (had been erroneously removed)
- Fix --strict-threads command-line option spelling
- Version embedded megahit binary
- Fixed inconsistency between reference identifiers and underlying files



Version 0.5.1
-------------

Released Nov 2 2017

Fixed some build issues

Version 0.5
-----------

Released Nov 1 2017

First release supporting all basic functionality.
