Elm.Native.Benchmark = {};
Elm.Native.Benchmark.make = function(localRuntime) {

	localRuntime.Native = localRuntime.Native || {};
	localRuntime.Native.Benchmark = localRuntime.Native.Benchmark || {};
	if (localRuntime.Native.Benchmark.values)
	{
		return localRuntime.Native.Benchmark.values;
	}

	//var Dict = Elm.Dict.make(localRuntime);
	var List = Elm.Native.List.make(localRuntime);
	//var Maybe = Elm.Maybe.make(localRuntime);
	var Task = Elm.Native.Task.make(localRuntime);
        var Signal = Elm.Signal.make(localRuntime);
        var Utils = Elm.Native.Utils.make(localRuntime);

        function makeBenchmark(name, thunk)
        {
            return {name : name, thunk : thunk};
        }


	function runWithProgress(maybeTaskFn, inSuite)
	{
            
	    return Task.asyncFunction(function(callback) {
                var bjsSuite = new Benchmark.Suite;
                var benchArray;
                var retData = [];
                var finalString = "";
                Task.perform(maybeTaskFn("Starting Benchmarks"));
                switch (inSuite.ctor)
                {
                    case "Suite":
                      benchArray = List.toArray(inSuite._1);
                      break;
                    case "SingleBenchmark":
                      benchArray = [inSuite._0 ];
                      break;
                }
                for (i = 0; i < benchArray.length; i++)
                {
                    bjsSuite.add(benchArray[i].name, benchArray[i].thunk );
                }
                bjsSuite.on('cycle', function(event) {
                   retData.push(
                       { name : event.target.options.name
                       , hz : event.target.hz
                       , marginOfError : event.target.stats.moe
                       , moePercent : event.target.stats.rme
                       }
                       );
                   finalString += String(event.target) + "\n";
                   console.log("Progress ");
                   var intermedString = String(event.target);
                   Task.perform(maybeTaskFn(intermedString));
                   //retString += String(event.target) + "\n";
                });
                bjsSuite.on('complete', function(event) {
                   finalString = "Final results:\n\n" + finalString;
                   Task.perform(maybeTaskFn(finalString) );
                   return callback(Task.succeed(Utils.Tuple2(finalString, retData)));
                });
                Task.perform(
                  Task.asyncFunction(function(otherCallback){
                      bjsSuite.run();
                  }));
        });
             }

	return localRuntime.Native.Benchmark.values = {
		makeBenchmark: F2(makeBenchmark),
		runWithProgress: F2(runWithProgress)
	};
                
   
};
