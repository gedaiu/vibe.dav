import dub_test_root;

import std.stdio;
import core.runtime;

shared bool result;

int main() {

	if(!result) {
		return 1;
	}

	writeln("All unit tests have been run successfully.");

	return 0;
}

shared static this() {
	import core.runtime;
	import std.exception;
	Runtime.moduleUnitTester = () => true;

	result = runUnitTests!allModules(new AtomTestResultWriter);
}
