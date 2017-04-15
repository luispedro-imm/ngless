#!/usr/bin/env cwl-runner
# This tool description was initially generated by argparse2tool ver. 0.4.3-2
# and later modified by hand

cwlVersion: v1.0

class: CommandLineTool
baseCommand: ['ngless-count.py']

requirements:
- $import: ngl-types.yml

doc: |
  None

inputs:
  input:
    type: File
    doc: SAM/BAM/CRAM file to count reads on
    inputBinding:
      prefix: --input

  output:
    type: string
    doc: Output file/path for results
    default: count-output.bam
    inputBinding:
      prefix: --output

  features:
    type: string?
    doc: Feature to count
    inputBinding:
      prefix: --features

  multiple:
    type: ngl-types.yml#multi_mappers?
    doc: How to handle reads that map to more than one location?
    inputBinding:
      prefix: --multiple

  debug:
    type: boolean?
    default: False
    doc: Prints the payload before submitting to ngless
    inputBinding:
      prefix: --debug

outputs:
  output_file:
    type: File
    outputBinding:
      glob: $(inputs.output)
