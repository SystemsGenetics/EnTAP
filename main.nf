#!/usr/bin/env nextflow

/**
 * ========
 * AnnoTater
 * ========
 *
 * Authors:
 *  + Stephen Ficklin
 *
 * Summary:
 *   A workflow for annotating Eukaryotic transcript sequences from whole genome
 *   or de novo transcriptome assemblies.
 */



println """\

General Information:
--------------------
  Profile(s):         ${workflow.profile}
  Container Engine:   ${workflow.containerEngine}

Input Files:
-----------------
  Transcript (mRNA) file:     ${params.input.transcript_fasta}

Data Files:
-----------------
  InterProScan data:          ${params.data.interproscan}
  Panther data:               ${params.data.panther}
  NCBI nr data:               ${params.data.nr}
  Uniprot SwissProt data:     ${params.data.sprot}

Output Parameters:
------------------
  Output directory:           ${params.output.dir}

"""
SEQS_FOR_IPRSCAN  = Channel.create()
SEQS_FOR_BLASTX_NR = Channel.create()
SEQS_FOR_BLASTX_SPROT = Channel.create()

/**
 * Read in the transcript sequences. We will process them in small chunks
 */
Channel.fromPath(params.input.transcript_fasta)
       .splitFasta(by: 10, file: true)
       .separate(SEQS_FOR_IPRSCAN, SEQS_FOR_BLASTX_NR, SEQS_FOR_BLASTX_SPROT) { a -> [a, a, a]}


// Get the input sequence filename and put it in a value Channel so we
// can re-use it multiple times.
matches = params.input.transcript_fasta =~ /.*\/(.*)/
SEQUENCE_FILENAME = Channel.value(matches[0][1])
SEQUENCE_FILENAME.subscribe{ println "filename: $it" }

process orthodb_index {
  label "diamond_makedb"
  cpus = 2

  output:
    file "*.dmnd" into ORTHODB_INDEXES

  when:
    params.steps.orthodb.enable == true

  script:
    if (params.data.orthodb.dbs.plants == true)
      """
      for species in ${params.data.orthodb.species.join(" ")}; do
        diamond makedb \
          --threads 2 \
          --in /annotater/orthodb/plants/Rawdata/\${species}_0.fs \
          --db \${species}
      done
      """
    else
      """
        echo "A database for OrthoDB has not been selected"
        echo ${params.data.orthodb.dbs.plants}
        exit 1
      """
}
/**
 * Prepares the Diamond indexes for the Uniprot Sprot database.
 */
process uniprot_sprot_index {
  label "diamond_makedb"
  cpus = 2

  output:
    file "*.dmnd" into SPROT_INDEX

  when:
    params.steps.dblastx_sprot.enable == true

  script:
  """
    diamond makedb \
      --threads 2 \
      --in /annotater/uniprot_sprot/uniprot_sprot.fasta \
      --db uniprot_sprot
  """
}
/**
 * Prepares the Diamond indexes for the NCBI nr database.
 */
process nr_index {
  label "diamond_makedb"
  cpus = 2
  memory = "6 GB"

  output:
    file "*.dmnd" into NR_INDEX

  when:
    params.steps.dblastx_nr.enable == true

  script:
  """
    diamond makedb \
      --threads 2 \
      --index-chunks 1000 \
      --in /annotater/nr/nr \
      --db nr
  """
}

/**
 * Runs InterProScan on each sequence
 */
process interproscan {
  label "interproscan"

  input:
    file seq from SEQS_FOR_IPRSCAN

  output:
    file "*.xml" into INTERPRO_XML
    file "*.tsv" into INTERPRO_TSV

  when:
    params.steps.interproscan.enable == true

  script:
    """
    # Call InterProScan on a single sequence.
    /usr/local/interproscan/interproscan.sh \
      -f TSV,XML \
      --goterms \
      --input ${seq} \
      --iprlookup \
      --pathways \
      --seqtype n \
      --cpu ${task.cpus} \
      --output-dir . \
      --mode standalone \
      --applications ${params.steps.interproscan.applications}
    # Remove the temp directory created by InterProScan
    rm -rf ./temp
    """
}

/*
 * Wait until all Interpro jobs have finished and combine
 * all result files into a single lsit
 */
INTERPRO_TSV.collect().set{ INTERPRO_TSV_FILES }

/**
 * Combine InterProScan results.
 */
process interproscan_combine {
  label "interproscan_combine"

  publishDir params.output.dir

  input:
    file tsv_files from INTERPRO_TSV_FILES
    val sequence_filename from SEQUENCE_FILENAME

  output:
    file "${sequence_filename}.IPR_mappings.txt" into IPR_MAPPINGS
    file "${sequence_filename}.GO_mappings.txt" into GO_MAPPINGS
    file "${sequence_filename}.tsv" into INTEPRO_TSV_COMBINED

  script:
  """
    interpro_combine.py ${sequence_filename}
  """
}

/**
 * Runs blastx against the NCBI non-redundant database.
 */
process dblastx_nr {
  label "diamond"

  input:
    file seq from SEQS_FOR_BLASTX_NR
    file index from NR_INDEX

  output:
    file "*_vs_nr.dblastx.xml" into BLASTX_NR_XML

  when:
    params.steps.dblastx_nr.enable == true

  script:
    """
    diamond blastx \
      --threads 1 \
      --query ${seq} \
      --db nr \
      --out ${seq}_vs_nr.dblastx.xml \
      --evalue 1e-6 \
      --outfmt 5
    """
}

/**
 * Runs blastx against the SwissProt database.
 */
process dblastx_sprot {
  label "diamond"

  input:
    file seq from SEQS_FOR_BLASTX_SPROT
    file index from SPROT_INDEX

  output:
    file "*_vs_uniprot_sprot.blastx.xml"  into BLASTX_SPROT_XML

  when:
    params.steps.dblastx_sprot.enable == true

  script:
    """
    diamond blastx \
      --threads 1 \
      --query ${seq} \
      --db uniprot_sprot \
      --out ${seq}_vs_uniprot_sprot.blastx.xml \
      --evalue 1e-6 \
      --outfmt 5
    """
}
