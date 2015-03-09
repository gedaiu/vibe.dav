/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 9, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.ifheader;

import tested;

import vibedav.parser;

import std.stdio;

struct IfCondition {

	private string[] _conditions;
	private string[] _notConditions;

	this(string condition) {
		parse(condition);
	}

	void addCondition(string condition) {
		parse(condition);
	}

	bool has(string condition) {
		foreach(i; 0.._conditions.length) {
			if(_conditions[i] == condition)
				return true;
		}

		return false;
	}

	bool hasNot(string condition) {
		foreach(i; 0.._notConditions.length) {
			if(_notConditions[i] == condition)
				return true;
		}

		return false;
	}

	private void parse(string data) {
		bool isNot;

		void addConditionCallback(string value) {
			if(isNot)
				_notConditions ~= value[1..$-1];
			else
				_conditions ~= value[1..$-1];
		}

		void notConditionCallback(string value) {
			isNot = true;
		}

		Parser parser;

		ParseInsideToken valueToken = new ParseInsideToken;
		valueToken.startChar = '<';
		valueToken.endChar = '>';
		valueToken.callback = &addConditionCallback;

		ParseStaticToken notToken = new ParseStaticToken;
		notToken.value = "Not";
		notToken.callback = &notConditionCallback;

		parser.tokens ~= valueToken;
		parser.tokens ~= notToken;
		parser.start(data);
	}
}

struct IfHeader {

	IfCondition list[string];

	@property {
		bool isEmpty() {
			return list.keys.length == 0;
		}
	}

	static IfHeader parse(string data) {
		IfHeader ifHeader;
		string path = "";

		void conditionTokenCallback(string data) {
			string condition = data[1..$-1];

			if(path !in ifHeader.list)
				ifHeader.list[path] = IfCondition(condition);
			else
				ifHeader.list[path].addCondition(condition);

			path = "";
		}

		void pathTokenCallback(string data) {
			path = data[1..$-1];
		}

		Parser parser;

		ParseInsideToken conditionToken = new ParseInsideToken;
		conditionToken.startChar = '(';
		conditionToken.endChar = ')';
		conditionToken.callback = &conditionTokenCallback;

		ParseInsideToken pathToken = new ParseInsideToken;
		pathToken.startChar = '<';
		pathToken.endChar = '>';
		pathToken.callback = &pathTokenCallback;

		parser.tokens ~= conditionToken;
		parser.tokens ~= pathToken;

		parser.start(data);

		return ifHeader;
	}
}

@name("No-Tag-List")
unittest {
	auto tag = IfHeader.parse("(<urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf>)");

	assert(tag.list.keys.length == 1);
	assert(tag.list[""].has("urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf"));
}

@name("Tagged-List")
unittest {
	auto tag = IfHeader.parse("<http://example.com/locked/> (<urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf>)");

	assert(tag.list.keys.length == 1);
	assert(tag.list["http://example.com/locked/"].has("urn:uuid:150852e2-3847-42d5-8cbe-0f4f296f26cf"));
}

@name("multiple conditions")
unittest {
	auto tag = IfHeader.parse("(<urn:uuid:181d4fae-7d8c-11d0-a765-00a0c91e6bf2>) (Not <DAV:no-lock>)");

	assert(tag.list.keys.length == 1);
	assert(tag.list[""].has("urn:uuid:181d4fae-7d8c-11d0-a765-00a0c91e6bf2"));
	assert(tag.list[""].hasNot("DAV:no-lock"));
}

