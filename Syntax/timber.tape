#!/usr/bin/env ducttape
global {
    ducttape_experimental_submitters=enable
    ducttape_experimental_imports=enable
}

import ../submitters.tape

# task Align

task LexicalProbs
    < source=$source
    < target=$target
    < alignment=$alignment
    > e2f
    > f2e
    :: scriptDir=@
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  perl $scriptDir/lex.perl --f $source --e $target --a $alignment --f2e $f2e --e2f $e2f
}

task GrammarExtraction
    < sourceTrees=$sourceTrees
    < targetTrees=$targetTrees
    < alignment=$alignment
    > rules
    > aligns
    :: numCores=$grammarExtractionCores
    :: timberRoot=@
    :: .submitter=torque_normal .walltime="01:00:00" {
  # Prepare to split the input files into chunks, one per core 
  tempDir=$(mktemp -d -p .)
  inputLineCount=$(cat $sourceTrees | wc -l)
  linesPerCore=$(expr $inputLineCount / $numCores + 1)

  # Time to split!
  split $sourceTrees -l $linesPerCore -d -a 2 $tempDir/sourceTrees
  split $targetTrees -l $linesPerCore -d -a 2 $tempDir/targetTrees
  split $alignment -l $linesPerCore -d -a 2 $tempDir/alignment

  # Run each of the pieces through the rule learner in parallel
  command="echo {} >&2; java -jar $timberRoot/grex/RuleLearner.jar $tempDir/sourceTrees{} $tempDir/targetTrees{} $tempDir/alignment{} 5 5 true false false 2 $tempDir/aligns{} > $tempDir/rules{}"
  seq -f "%02g" 0 $(expr $numCores - 1) | parallel -j $numCores "$command" 

  # Concatenate all the outputs
  for n in `seq -f "%02g" 0 $(expr $numCores - 1)`
  do
    cat $tempDir/rules$n >> $rules
    cat $tempDir/aligns$n >> $aligns
  done

  # Clean up
#  rm -rf $tempDir 
}

task CollectNonTerminalCounts
    < rules=@GrammarExtraction
    > ntCounts
    :: scriptDir=@
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  cat $rules | perl $scriptDir/collect-nt-pair-counts.pl > $ntCounts
}

task ConvertGrammarFormat
    < rules=@GrammarExtraction
    > grammar
    > scoreNames
    :: scriptDir=@
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  pv $rules | python $scriptDir/convert_grammar_format.py -j > $grammar
  echo 'count' > $scoreNames
}

# task RunLabelCollapser
# task CollapseLabels

task CollectRuleCounts
    < grammar=@ConvertGrammarFormat
    < inputScoreNames=$scoreNames@ConvertGrammarFormat
    > scoredGrammar
    > scoreNames
    :: scriptDir=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  touch $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 1,4 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | python $scriptDir/collect_rule_counts.py $inputScoreNames $scoreNames > $scoredGrammar
  rm $sortedGrammar
}


task ScorePhrasalSGT
    < grammar=$scoredGrammar@CollectRuleCounts
    < inputScoreNames=$scoreNames@CollectRuleCounts
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 4,4 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-phrase-sgt.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScorePhrasalTGS
    < grammar=$scoredGrammar@ScorePhrasalSGT
    < inputScoreNames=$scoreNames@ScorePhrasalSGT
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 3,3 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-phrase-tgs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreLGR
    < grammar=$scoredGrammar@ScorePhrasalTGS
    < inputScoreNames=$scoreNames@ScorePhrasalTGS
    > scoredGrammar
    > scoreNames 
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 3,4 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-lhs-given-rhs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreRGL
    < grammar=$scoredGrammar@ScoreLGR
    < inputScoreNames=$scoreNames@ScoreLGR
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 2,2 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-rhs-given-lhs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task WidenGrammarFormat
    < grammar=$scoredGrammar@ScoreRGL
    < inputScoreNames=$scoreNames@ScoreRGL
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  pv $grammar | perl $timberRoot/grascore/widen-format.pl > $scoredGrammar
  pv $inputScoreNames > $scoreNames
}

task ScoreSourceLGR
    < grammar=$scoredGrammar@WidenGrammarFormat
    < inputScoreNames=$scoreNames@WidenGrammarFormat
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 4,4 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-wide-slhs-given-srhs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreTargetLGR
    < grammar=$scoredGrammar@ScoreSourceLGR
    < inputScoreNames=$scoreNames@ScoreSourceLGR
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 5,5 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-wide-tlhs-given-trhs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreSourceRGL
    < grammar=$scoredGrammar@ScoreTargetLGR
    < inputScoreNames=$scoreNames@ScoreTargetLGR
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 2,2 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-wide-srhs-given-slhs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreTargetRGL
    < grammar=$scoredGrammar@ScoreSourceRGL
    < inputScoreNames=$scoreNames@ScoreSourceRGL
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 3,3 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-wide-trhs-given-tlhs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreRuleSGT
    < grammar=$scoredGrammar@ScoreTargetRGL
    < inputScoreNames=$scoreNames@ScoreTargetRGL
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 3,3 -k 5,5 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-wide-cfg-sgt.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task ScoreRuleTGS
    < grammar=$scoredGrammar@ScoreRuleSGT
    < inputScoreNames=$scoreNames@ScoreRuleSGT
    > scoredGrammar
    > scoreNames 
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@
    :: .submitter=torque_normal .walltime="24:00:00" {
  sortedGrammar="./sorted"
  cp $inputScoreNames $scoreNames
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 2,2 -k 4,4 --parallel=$sortCores > $sortedGrammar
  pv $sortedGrammar | perl $timberRoot/grascore/score-wide-cfg-tgs.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
  rm $sortedGrammar
}

task NarrowGrammarFormat
    < grammar=$scoredGrammar@ScoreRuleTGS
    < inputScoreNames=$scoreNames@ScoreRuleTGS
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  pv $grammar | perl $timberRoot/grascore/narrow-format.pl > $scoredGrammar
  pv $inputScoreNames > $scoreNames
}

# Downstream steps assume the grammar is sorted by right hand side.
task ResortForConvenience
    < grammar=$scoredGrammar@NarrowGrammarFormat
    < inputScoreNames=$scoreNames@NarrowGrammarFormat
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: sortCores=@
    :: sortRAM=@
    :: sortTempDir=@ 
    :: .submitter=torque_normal .walltime="24:00:00" {
  pv $grammar | LC_ALL=C sort -S $sortRAM -T $sortTempDir -t $'\t' -k 3,4 --parallel=$sortCores > $scoredGrammar
  pv $inputScoreNames > $scoreNames
}

# This step scores both p(source LHS | target LHS) and
# p(target LHS | source LHS).
task ScoreLabelMatch
    < grammar=$scoredGrammar@ResortForConvenience
    < inputScoreNames=$scoreNames@ResortForConvenience
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cp $inputScoreNames $scoreNames
  pv $grammar | perl $timberRoot/grascore/get-nt-pair-counts.pl tab $scoreNames > ./pairCountsOut
  pv $grammar | perl $timberRoot/grascore/add-label-match-probs.pl ./pairCountsOut $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
}

task ScoreLexProbs
    < grammar=(UseNewFeatures: no=$scoredGrammar@ScoreRGL yes=$scoredGrammar@ScoreLabelMatch)
    < inputScoreNames=(UseNewFeatures: no=$scoreNames@ScoreRGL yes=$scoreNames@ScoreLabelMatch)
    < lexE2F=$e2f@LexicalProbs
    < lexF2E=$f2e@LexicalProbs
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cp $inputScoreNames $scoreNames
  pv $grammar | perl $timberRoot/grascore/add-lex-probs-jon.pl $lexE2F $lexF2E $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
}

task ScoreRarity
    < grammar=$scoredGrammar@ScoreLexProbs
    < inputScoreNames=$scoreNames@ScoreLexProbs
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cp $inputScoreNames $scoreNames
  pv $grammar | perl $timberRoot/grascore/add-rarity-score.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
}

task ScoreFullyAbstract
    < grammar=$scoredGrammar@ScoreRarity
    < inputScoreNames=$scoreNames@ScoreRarity
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cp $inputScoreNames $scoreNames
  pv $grammar | perl $timberRoot/grascore/add-fully-abs-bin.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
}

task ScoreFullyLexical
    < grammar=$scoredGrammar@ScoreFullyAbstract
    < inputScoreNames=$scoreNames@ScoreFullyAbstract
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cp $inputScoreNames $scoreNames
  pv $grammar | perl $timberRoot/grascore/add-fully-lex-bin.pl $scoreNames > $scoredGrammar
  mv $scoreNames.new $scoreNames
}

task ScoreGlue
    < grammar=$scoredGrammar@ScoreFullyLexical
    < inputScoreNames=$scoreNames@ScoreFullyLexical
    > scoredGrammar
    > scoreNames
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cp $grammar $scoredGrammar
  cat $inputScoreNames | sed 's/$/ glue?/' > $scoreNames
}

task CreateGlueGrammar
    < grammar=$scoredGrammar@ScoreGlue
    > glueGrammar
    :: scriptDir=@
    :: .submitter=torque_shared .walltime="04:00:00" .cpus=1 .vmem=40g {
  cat $grammar | cut -f 2 | python $scriptDir/create_glue_grammar.py > $glueGrammar
}

task FindOOVs
    < testSetSource=(TuneOrTest: test=$testSetSource tune=$tuneSetSource)  
    < scoredGrammar=@CollectRuleCounts
    > oovs
    :: scriptDir=@
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  python $scriptDir/findOOVs.py $scoredGrammar $testSetSource > $oovs
}

task CreateSentenceGlueGrammars  
    < testSetSourceTrees=(TuneOrTest: test=$testSetSourceTrees tune=$tuneSetSourceTrees)
    < oovs=@FindOOVs
    < ntCounts=@CollectNonTerminalCounts
    > outputDir
    :: scriptDir=@
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  mkdir $outputDir
  pv $testSetSourceTrees | python $scriptDir/extract_glue_rules.py $oovs $ntCounts $outputDir  
}

task FilterToTestSet
    < fullGrammar=$scoredGrammar@ScoreGlue
    < trainTargetTrees=$targetTrees
    < source=(TuneOrTest: test=$testSetSource tune=$tuneSetSource)
    < scoreNames=$scoreNames@ScoreGlue
    > filteredGrammarsDir
    :: numCores=$filteringCores
    :: timberRoot=@
    :: scriptDir=@
    :: .submitter=torque_normal .walltime="72:00:00" {
  cp $scoreNames ./scoreNames
  bash $scriptDir/filtering.sh $fullGrammar $source $trainTargetTrees ./scoreNames $numCores $filteredGrammarsDir 0.3776
}

task CombineGrammars
    < filteredGrammarsDir=@FilterToTestSet
    < glueGrammarDir=$outputDir@CreateSentenceGlueGrammars
    > outputDir
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  mkdir $outputDir
  for f in `ls -1 $filteredGrammarsDir`;
  do
    i=$(echo $f | cut -f 1 -d '.')
    cp $filteredGrammarsDir/$i.gz $outputDir/$i.gz
    cat $glueGrammarDir/$i.txt | gzip >> $outputDir/$i.gz
  done
}

task MakeCdecIni
    < languageModel=$languageModel
    < glueGrammar=$glueGrammar@CreateGlueGrammar
    > cdecIni {
  echo "formalism=scfg" > $cdecIni
  echo "scfg_no_hiero_glue_grammar=true" >> $cdecIni
  echo "feature_function=KLanguageModel -n N4LM $languageModel" >> $cdecIni
  echo "scfg_extra_glue_grammar=$glueGrammar" >> $cdecIni
  echo "feature_function=WordPenalty" >> $cdecIni
  echo "add_pass_through_rules=true" >> $cdecIni
  echo "density_prune=100" >> $cdecIni
}

task Tune
    < filteredGrammarsDir=$outputDir@CombineGrammars[TuneOrTest:tune]
    < tuneSource=$tuneSetSource
    < tuneRefs=$tuneSetRefs
    < cdecIni=$cdecIni@MakeCdecIni
    > optimizedWeights
    :: useNewFeatures=(UseNewFeatures: no="1" yes="0")
    :: tuningRunNumber=@
    :: numCores=$decodeCores
    :: timberRoot=@
    :: scriptDir=@
    :: .submitter=torque_normal .walltime="72:00:00" {
  initialWeights="initialWeights.txt"
  wrappedDevSet="wrappedDevSet.txt"
  workDir="./mert-work"

  echo "WordPenalty -0.38"  > $initialWeights
  echo "PassThrough -0.06" >> $initialWeights
  echo "N4LM 1.12"         >> $initialWeights
  echo "N4LM_OOV -1.12"    >> $initialWeights
  echo "rarity 0.07"       >> $initialWeights
  echo "phrase-SGT -1.81"  >> $initialWeights
  echo "phrase-TGS -2.91"  >> $initialWeights
  echo "lhsGrhs -1.21"     >> $initialWeights
  echo "rhsGlhs -1.21"     >> $initialWeights
  if [[ $useNewFeatures ]]; then
    echo "slhsGsrhs -0.61"   >> $initialWeights
    echo "tlhsGtrhs -0.61"   >> $initialWeights
    echo "srhsGslhs -0.51"   >> $initialWeights
    echo "trhsGtlhs -0.51"   >> $initialWeights
    echo "cfg-SGT -0.91"     >> $initialWeights
    echo "cfg-TGS -1.46"     >> $initialWeights
    echo "lhs-SGT -0.31"     >> $initialWeights
    echo "lhs-TGS -0.41"     >> $initialWeights
  fi
  echo "lexical-SGT -0.52" >> $initialWeights
  echo "lexical-TGS -0.94" >> $initialWeights
  echo "abstract? 0.56"    >> $initialWeights
  echo "lexical? 1.79"     >> $initialWeights
  echo "glue? -1.25"       >> $initialWeights

  paste -d $'\t' $tuneSource $tuneRefs | sed 's/\t/\|\|\|/g' > ./DevSet
  cat ./DevSet | python $scriptDir/wrapCorpus.py $filteredGrammarsDir > $wrappedDevSet
  perl $timberRoot/cdec/training/dpmert/dpmert.pl --devset $wrappedDevSet --weights $initialWeights --jobs $numCores --output-dir $workDir --config $cdecIni

  index=$(ls $workDir | grep '^weights\.[0-9]*$' | sed 's/^weights\.//' | sort -n | tail -n 1)
  ln -s $workDir/weights.$index $optimizedWeights
}

task TuneWithMIRA
    < filteredGrammarsDir=$outputDir@CombineGrammars[TuneOrTest:tune]
    < tuneSource=$tuneSetSource
    < tuneRefs=$tuneSetRefs
    < cdecIni=@MakeCdecIni
    > optimizedWeights
    :: useNewFeatures=(UseNewFeatures: no="1" yes="0")
    :: tuningRunNumber=@
    :: numCores=$decodeCores
    :: timberRoot=@
    :: scriptDir=@
    :: .submitter=torque_normal .walltime="72:00:00" {
  initialWeights="initialWeights.txt"
  wrappedSource="wrappedSource.txt"
  wrappedCorpus="wrappedCorpus.txt"
  workDir="./mira-work"

  echo "WordPenalty 0.0" >  $initialWeights
  echo "PassThrough 0.0" >> $initialWeights
  echo "N4LM 0.0"        >> $initialWeights
  echo "N4LM_OOV 0.0"    >> $initialWeights
  echo "rarity 0.0"      >> $initialWeights
  echo "phrase-SGT 0.0"  >> $initialWeights
  echo "phrase-TGS 0.0"  >> $initialWeights
  echo "lhsGrhs 0.0"     >> $initialWeights
  echo "rhsGlhs 0.0"     >> $initialWeights
  if [[ $useNewFeatures ]]; then
    echo "slhsGsrhs 0.0"   >> $initialWeights
    echo "tlhsGtrhs 0.0"   >> $initialWeights
    echo "srhsGslhs 0.0"   >> $initialWeights
    echo "trhsGtlhs 0.0"   >> $initialWeights
    echo "cfg-SGT 0.0"     >> $initialWeights
    echo "cfg-TGS 0.0"     >> $initialWeights
    echo "lhs-SGT 0.0"     >> $initialWeights
    echo "lhs-TGS 0.0"     >> $initialWeights
  fi
  echo "lexical-SGT 0.0" >> $initialWeights
  echo "lexical-TGS 0.0" >> $initialWeights
  echo "abstract? 0.0"   >> $initialWeights
  echo "lexical? 0.0"    >> $initialWeights
  echo "glue? 0.0"       >> $initialWeights

  cat $tuneSource | python $scriptDir/wrapCorpus.py $filteredGrammarsDir > $wrappedSource
  #perl $timberRoot/cdec/training/mira/run_mira.pl --pseudo-doc --max-iterations 20 --optimizer 2 --unique-kbest --use-make $numCores --jobs $numCores \
  #  --kbest-size 500 --update-size 500 --hope-select 1 --fear-select 1 --step-size 0.01 --metric-scale 1 --workdir $workDir --weights $initialWeights \
  #--source-file $wrappedSource --ref-files "$tuneRefs" $cdecIni
  paste $wrappedSource $tuneRefs | sed 's/\t/ ||| /g' > $wrappedCorpus
  python ~/git/timber/cdec/training/mira/mira.py --kbest-size 500 -j $numCores -o $workDir -w $initialWeights -c $cdecIni -d $wrappedCorpus

  ln -s $workDir/weights.final $optimizedWeights
}

task Decode
    < testSource=(TuneOrTest: test=$testSetSource tune=$tuneSetSource)
    < filteredGrammarsDir=$outputDir@CombineGrammars cdecIni=$cdecIni@MakeCdecIni
    < optimizedWeights=(Optimizer: mert=$optimizedWeights@Tune mira=$optimizedWeights@TuneWithMIRA)
    > output
    :: numCores=$decodeCores
    :: timberRoot=@
    :: scriptDir=@
    :: .submitter=torque_normal .walltime="72:00:00" {
  wrappedSource="wrappedSource.txt" 
  cat $testSource | python $scriptDir/wrapCorpus.py $filteredGrammarsDir > $wrappedSource
  date > timestamps.txt
  bash $scriptDir/decode.sh $wrappedSource $cdecIni $optimizedWeights $numCores > $output
  date >> timestamps.txt
}

task Evaluate
    < output=$output@Decode
    < refs=(TuneOrTest: test=$testSetRefs tune=$tuneSetRefs)
    > bleu
    > meteor
    > ter
    > length
    :: timberRoot=@
    :: .submitter=torque_shared .walltime="01:00:00" .cpus=1 .vmem=40g {
  METEORTASK=li
  METEORLANG=other
  scoreFile=scores.txt
  ln -s $timberRoot/multeval/constants .
  $timberRoot/multeval/multeval.sh eval --refs $refs --hyps-baseline $output --meteor.task $METEORTASK --meteor.language $METEORLANG &> $scoreFile
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 2 > $bleu
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 3 > $meteor
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 4 > $ter
  tail -n 2 $scoreFile | head -n 1 | sed 's/(\S\+)//g' | sed 's/\s\+/\t/g' | cut -f 5 > $length
}

summary EvaluationSummary {
  of Evaluate > Score {
    cp $bleu $Score
  }
}