(* ::Package:: *)

(* Connector that translates between the MC19 model and
the input/output schema used by the unified modelling UI. *)

(* Exit whenever an error message is raised. *)
messageHandler = If[Last[#], Exit[1]] &;
Internal`AddHandler["Message", messageHandler];

(* Command-line arguments: <inputFile> <outputFile> *)
(* Input file must exist, output file will be created. *)
connector::missingArguments = "Expected 2 script arguments <inputFile> <outputFile>, received `1`";
numArgs = Length[$ScriptCommandLine] - 1;
If[
  numArgs < 2,
  Message[connector::missingArguments, numArgs]
];

connector::missingEnvVar = "Environment variable `1` is not set";
repoRoot = Environment["MODEL_REPO_ROOT"];
If[
  repoRoot == $Failed,
  Message[connector::missingEnvVar, "MODEL_REPO_ROOT"]
];

dataPath = repoRoot <> "/model/data.wl";
Print["Importing model data from ", dataPath];
Import[dataPath];
Print["Imported model data"];

(* TODO: Set these simulation dates. Variables are globals from data.wl *)
(* tmax0 = 365 * 2;
tmin0 = 1;
may1=121; *)

(* Translates a date string into an integer,
which states the number of days from 1 Jan 2020 to the given date
(inclusive, starting at 0). *)
translateDateIntoOffset[dateString_]:=Module[{
  start2020,
  date
},
  start2020 = DateString["2020-01-01", "ISODate"];
  date=DateString[dateString, "ISODate"];
  DayCount[start2020, date]
];

(* Reads GitHub unified UI input JSON from the given file. *)
readInputJson[inputPath_] := Import[inputPath, "RawJSON"];

(*
Translates GitHub unified UI `ModelInput` JSON into a pair of {distancing, stateCode}.
Here `distancing` is a rule describing a distancing function,
which can be placed in the `stateDistancingPrecomputed` structure,
and `stateCode` is the ISO 2-letter code for the US state being run on.
*)
translateInput[modelInput_, presetData_]:=Module[{
  stateCode,
  interventionPeriods,
  interventionDistancingLevels,
  interventionStartDateOffsets,
  interventionEndDateOffsets,
  interventionDistancing,
  fullDistancing,
  presetDistancingData,
  distancingRatio,
  getScalingDate,
  getScalingFactor,
  scale,
  lastInterventionStartDate,
  fullDistancingUnadjusted,
  smoothing,
  SlowJoin,
  fullDays,
  smoothedFullDistancing,
  distancingFunction
},
  (* Only US states are currently supported *)
  connector::unsupportedRegion = "Only the US region is currently supported. Received `1`";
  If[
    modelInput["region"] != "US",
    Message[connector::unsupportedRegion, modelInput["region"]],
    ""
  ];
  Print[modelInput["region"]];
  (* Drop the US- prefix *)
  stateCode = StringDrop[modelInput["subregion"], 3];

  (* Only some US states are supported. Check against the precomputed model data. *)
  connector::unsupportedSubregion = "Subregion `1` is the state `2`, which is not currently supported.";
  Print[!KeyExistsQ[presetData, stateCode]];
  If[
    !KeyExistsQ[presetData, stateCode],
    Message[connector::unsupportedSubregion, modelInput["subregion"], stateCode]
  ];

  interventionPeriods = modelInput["parameters"]["interventionPeriods"];
  (* Here we use the estimated reduction in population contact from the input.
  This is in [0..100] (0 = no distancing, 100 = total isolation).
  Turn it into a distancing level in [0..1] (0 = total isolation, 1 = no distancing).
  TODO: Should we use the named interventions and their intensity? *)
  interventionDistancingLevels = Map[((100-#["reductionPopulationContact"])/100.)&, interventionPeriods];
  interventionStartDateOffsets = Map[translateDateIntoOffset[#["startDate"]]&, interventionPeriods];
  (* Treat start dates as inclusive and end dates as exclusive.
  endDate[i] = startDate[i+1] for 1 <= i < len, and endDate[len] = tMax+1
  This assumes post-policy distancing is provided as the last intervention period. *)
  interventionEndDateOffsets = Drop[Append[interventionStartDateOffsets, tmax0+1], 1];

  (* List of lists describing policy distancing from interventions.
  Each list is a time series for one intervention period,
  with the distancing level at each day.
  0 = 100% contact reduction/total isolation.
  1 = 0% contact reduction/no distancing.
  *)
  interventionDistancingUnadjusted = Prepend[
    MapThread[
      Function[
        {startOffset, endOffset, distancingLevel},
        (* Duration of each intervention: endDate[i]-startDate[i].
        Note this treats each period as being start-inclusive, end-exclusive. *)
        ConstantArray[distancingLevel, endOffset-startOffset]
      ],
      {
        interventionStartDateOffsets,
        interventionEndDateOffsets,
        interventionDistancingLevels
      }
    ],
    (* Pre-policy distancing - constant at 1 from 1 Jan 2020 to start of policy.*)
    ConstantArray[1., interventionStartDateOffsets[[1]]]
    (* Here we assume historical data is already included in the inputs from the UI.*)
  ];

  (* Flatten the list of lists into a single time series list. *)
  fullDistancingUnadjusted = Flatten[interventionDistancingUnadjusted];

  (* Scale the distancing levels.
  The scaling is derived from the historical data being passed in and the
  historical data imported by the model.
  Create an interpolating function that describes the ratio between these two data series.
  Then apply that function to extrapolate how to scale intervention levels from the present day onwards.
  *)
  Print["Scaling distancing data"];
  presetDistancingData = presetData[stateCode][scenario5["id"]]["distancingData"];

  (* The pointwise ratios or scaling factors between:
  - the historical distancing data obtained by the model from its own sources
  - the historical distancing data passed in from the unified UI. *)
  On[Assert];
  Assert[Length[presetDistancingData] == Length[fullDistancingUnadjusted]];
  Off[Assert];
  distancingRatio = Take[presetDistancingData/fullDistancingUnadjusted, today];
  Print["Ratios of historical distancing data: ", distancingRatio];
  (* Fit a function to the scaling factors by interpolation. *)
  getScalingFactor = Interpolation[distancingRatio];

  (* Scale future distancing levels by extrapolation.
  This is intended to mitigate variation between the two sources of distancing data.*)
  lastInterventionStartDate = Last[interventionStartDateOffsets]+1;
  Print["Last intervention start date: ", lastInterventionStartDate];
  (* The last intervention is assumed to be constant
    (either zero or the last distancing level continued until the end of simulation).
    An interpolating polynomial function will eventually diverge from this constant value,
    so for time points in the last intervention period,
    we calculate how the scaling factor for the start date of that intervention period,
    and scale constantly by that factor throughout the last intervention.*)
  getScalingDate = Function[
    Typed[t, "UnsignedInteger32"],
    Min[t, lastInterventionStartDate]
  ];
  scale = Function[
    {
      Typed[unscaledValue, "Real64"],
      Typed[ts, TypeSpecifier["NumericArray"]["UnsignedInteger32", 1]]
    },
    (* Cannot be less than 0 or greater than 1. *)
    Max[0, Min[1, getScalingFactor[getScalingDate[First[ts]]] * unscaledValue]]
  ];
  fullDistancing = MapIndexed[
    scale,
    fullDistancingUnadjusted
  ];

  scalingIndex = 1;
  (* int[][] *)interventionDistancing = {};
  For[i = 1, i <= Length[interventionDistancingUnadjusted], i++,
    segment = interventionDistancingUnadjusted[[i]];
    (* int[] *)newSegment = {};
    For[j = 1, j <= Length[segment], j++,
      AppendTo[newSegment, scale[segment[[j]], {scalingIndex}]];
      scalingIndex++;
    ];
    AppendTo[interventionDistancing, newSegment];
  ];

  Print["Last intervention unscaled: ", fullDistancingUnadjusted[[lastInterventionStartDate]]];
  Print["Last intervention scaled: ", fullDistancing[[lastInterventionStartDate]]];
  Print["Last scaling factor: ", getScalingFactor[lastInterventionStartDate]];

  Print["Last intervention segment unscaled: ", Last[interventionDistancingUnadjusted]];
  Print["Last intervention segment scaled: ", Last[interventionDistancing]];
  
  Print["Unscaled distancing data: ", fullDistancingUnadjusted];
  Print["Scaled distancing data: ", fullDistancing];

  (* TODO: These are copied from modules in data.wl,
  and should be shared instead. *)
  smoothing = 7;
  SlowJoin := Fold[Module[{smoother},
      smoother=1-Exp[-Range[Length[#2]]/smoothing];
      Join[#1, Last[#1](1-smoother)+#2 smoother]]&];
  fullDays = Range[0, tmax0];
  smoothedFullDistancing = SlowJoin[interventionDistancing];

  (* Domain and range length must match for us to interpolate. *)
  On[Assert];
  Assert[Length[fullDistancing] == Length[fullDays]];
  Off[Assert];

  distancingDelay = 5;
  Which[
    distancingDelay>0,
    smoothedFullDistancing=Join[ConstantArray[1,distancingDelay], smoothedFullDistancing[[;;-distancingDelay-1]]];,
    distancingDelay<0,
    smoothedFullDistancing=Join[smoothedFullDistancing[[distancingDelay+1;;]], ConstantArray[1,Abs[distancingDelay]]];
  ];

  distancingFunction = Interpolation[
    Transpose[{
      fullDays,
      smoothedFullDistancing
    }],
    InterpolationOrder->3
  ];

  {
    <|
      "distancingDays"->fullDays,
      (* Deliberately omitted: distancingLevel. *)
      "distancingData"->fullDistancing,
      "distancingFunction"->distancingFunction
      (* Deliberately omitted: mostRecentDistancingDay. *)
    |>,
    stateCode
  }
];

(*
Translates time series data produced by GenerateModelExport
into GitHub unified UI output JSON (`ModelOutput`).
*)
translateOutput[modelInput_, stateCode_, timeSeriesData_] := Module[{
  timestamps,
  metrics,
  zeroes,
  cumMild,
  cumSARI,
  cumCritical,
  modelOutput
},
  timestamps = Map[#["day"]&, timeSeriesData];
  zeroes = ConstantArray[0., Length[timeSeriesData]];
  cumMild = Map[#["cumulativeMildOrAsymptomatic"]["expected"]&, timeSeriesData];
  cumSARI = Map[#["cumulativeHospitalized"]["expected"]&, timeSeriesData];
  cumCritical = Map[#["cumulativeCritical"]["expected"]&, timeSeriesData];
  metrics = <|
    "Mild" -> Map[#["currentlyMildOrAsymptomatic"]["expected"]&, timeSeriesData],
    (* Included in mild. *)
    "ILI" -> zeroes,
    "SARI" -> Map[#["currentlyHospitalized"]["expected"]&, timeSeriesData],
    "Critical" -> Map[#["currentlyCritical"]["expected"]&, timeSeriesData],
    (* Cases going from critical back to severe.
    Not measured separately by this model, so supply zero. *)
    "CritRecov" -> zeroes,
    "incDeath" -> Map[#["dailyDeath"]["expected"]&, timeSeriesData],
    "cumMild" -> cumMild,
    "cumILI" -> zeroes,
    "cumSARI" -> cumSARI,
    "cumCritical" -> cumCritical,
    (* See CritRecov. *)
    "cumCritRecov" -> zeroes
  |>;
  modelOutput = <|
    "metadata" -> modelInput,
    "time" -> <|
      "t0" -> DateString["2020-01-01", "ISODate"],
      "timestamps" -> timestamps,
      "extent" -> {First[timestamps], Last[timestamps]}
    |>,
    "aggregate" -> <|
      "metrics" -> metrics
    |>
  |>;
  modelOutput
];

(* Index 1 is this .wl file, so arguments start at 2. *)
inputFile = $ScriptCommandLine[[2]];
outputFile = $ScriptCommandLine[[3]];

Print["Reading input from unified UI, stored at ", inputFile];
modelInput = readInputJson[inputFile];

Print["Translating input from unified UI"];
{customDistancing, stateCode} = translateInput[
  modelInput,
  stateDistancingPrecompute
];
Print["Length of distancingDays: ", Length[customDistancing["distancingDays"]]];
Print["Length of distancingData: ", Length[customDistancing["distancingData"]]];
Print["The model will be run for: " <> stateCode];

(* We leave the existing scenarios so that param fitting can take place against them,
but add a new scenario and distancing function that describes our input set of interventions.
These are defined in the `data` package but used in `model`.
So we modify them here, between the two imports.
*)
customScenario=<|"id"->"customScenario","name"->"Custom", "gradual"->False|>;
Print["Adding a custom scenario and distancing function to the precomputed data"];
(* For simplicity, remove all other scenarios,
except scenario1 which is needed for fitting,
and scenario5 (Current Indefinite), which is used
to produce data for comparison and debugging.*)
scenarios={scenario1, scenario5, customScenario};
stateDistancingPrecompute[stateCode] = Append[
  stateDistancingPrecompute[stateCode],
  customScenario["id"] -> customDistancing
];

(* Import the `model` package, but ensure it does not re-import the `data` package,
since we have already imported from `data` and modified its global variables. *)
Print["Importing model"];
isDataImported = True
Import[Environment["MODEL_REPO_ROOT"] <> "/model/model.wl"];

Print["Modified list of scenarios: ", scenarios];
Print["Precomputed distancing days for custom scenario: ", stateDistancingPrecompute[stateCode][customScenario["id"]]["distancingDays"]];
Print["Precomputed distancing data for custom scenario: ", stateDistancingPrecompute[stateCode][customScenario["id"]]["distancingData"]];

Print["Running model"];
(* Create these directories so the model export can write to them. *)
Map[
  Function[scenario, CreateDirectory["public/json/"<>stateCode<>"/"<>scenario["id"]]],
  scenarios
];
CreateDirectory["tests"];
data = GenerateModelExport[1, {stateCode}];

Print["Translating output for unified UI"];
timeSeriesData = data[stateCode]["scenarios"][customScenario["id"]]["timeSeriesData"];
timeSeriesDataS5 = data[stateCode]["scenarios"][scenario5["id"]]["timeSeriesData"];
modelOutput = translateOutput[modelInput, stateCode, timeSeriesData];
modelOutputS5 = translateOutput[modelInput, stateCode, timeSeriesDataS5];

Print["Writing output for unified UI to ", outputFile];
Export[DirectoryName[outputFile] <> "/rawTimeSeries.json", timeSeriesData];
Export[DirectoryName[outputFile] <> "/rawTimeSeries.s5.json", timeSeriesDataS5];
Export[outputFile, modelOutput];
Export[DirectoryName[outputFile] <> "/data.s5.json", modelOutputS5];
