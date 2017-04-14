#!/usr/bin/env cwl-runner
# This tool description was initially generated by argparse2tool ver. 0.4.3-2
# and later modified by hand

cwlVersion: v1.0

class: CommandLineTool
baseCommand: ['ngless-mapstats.py']

doc: |
  None

inputs:

  input:
    type: File
    doc: SAM/BAM/CRAM file filter
    inputBinding:
      prefix: --input

  output:
    type: string
    doc: Output file/path for results
    default: output.stats
    inputBinding:
      prefix: --output

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
