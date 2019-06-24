// = Apple.com Detection Library =
//
// A package consisting of a variety of functions for detecting various
// capabilities about a specified user agent.
//
// While browser detection is frowned up, there is a definite need at times.
// Just use it for the right reasons.
//
// Be sure to check the extensive unit testing for this package in
// the sandbox. But keep in mind that optimizations made to this file have
// broken the tests. Specifically, anytime the result of the test is cached
// the test is not re-evaluated.
//

if (typeof(AC) === "undefined") {
    AC = {};
}

// == AC.Detector ==
// The package all detection functions are stored within.
AC.Detector = {

    // ** {{{ AC.Detector.getAgent() }}} **
    //
    // Returns the name of the user agent, normalized as all lower case.
    getAgent: function()
    {
        return navigator.userAgent.toLowerCase();
    },

    // ** {{{ AC.Detector.isMac() }}} **
    //
    // Returns whether or not the platform is a Mac.
    isMac: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return !!agent.match(/mac/i);
    },

	// ** {{{ AC.Detector.isSnowLeopard() }}} **
	//
	// Returns whether or not the OS is Snow Leopard
	isSnowLeopard: function(userAgent)
	{
		var agent = userAgent || this.getAgent();
		return !!agent.match(/mac os x 10_6/i);
	},

    // ** {{{ AC.Detector.isWin() }}} **
    //
    // Returns whether or nor the platform is Windows, regardless of version.
    isWin: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return !!agent.match(/win/i);
    },

    // ** {{{ AC.Detector.isWin2k() }}} **
    //
    // Returns whether or not the platform is Windows 2000.
    isWin2k: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return this.isWin(agent) && (agent.match(/nt\s*5/i));
    },

    // ** {{{ AC.Detector.isWinVista() }}} **
    //
    // Returns whether or not the platform is Windows Vista.
    isWinVista: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return this.isWin(agent) && (agent.match(/nt\s*6/i));
    },

    // ** {{{ AC.Detector.isWebKit() }}} **
    //
    // Returns whether or not the user agent is using the webkit engine.
    isWebKit: function(userAgent)
    {
        if(this._isWebKit === undefined) {
            var agent = userAgent || this.getAgent();
            this._isWebKit =  !!agent.match(/AppleWebKit/i);
            this.isWebKit = function() {
                return this._isWebKit;
            };
        }
        return this._isWebKit;
    },

    // ** {{{ AC.Detector.isSafari2() }}} **
    //
    // Returns whether or not the user agent is Safari 2.
    isSafari2: function(userAgent)
    {
        if(this._isSafari2 === undefined) {
            if (!this.isWebKit()) {
                this._isSafari2 = false;
            } else {
                var ua = navigator.userAgent.toLowerCase();
               var version = parseInt(parseFloat(ua.substring(ua.lastIndexOf('safari/') + 7)), 10);
                this._isSafari2 = (version >= 419);
            }
            this.isSafari2 = function() {
                return this._isSafari2;
            };
        }
        return this._isSafari2;
    },

	// ** {{{ AC.Detector.isChrome() }}} **
	//
	// Returns whether or not the user agent is Chrome.
	isChrome: function(userAgent)
	{
		if(this._isChrome === undefined) {
			var agent = userAgent || this.getAgent();
			this._isChrome = !!agent.match(/Chrome/i);
			this.isChrome = function() {
				return this._isChrome;
			};
		}
		return this._isChrome;
	},

    // ** {{{ AC.Detector.isOpera() }}} **
    //
    // Returns whether or not the user agent is Opera
    isOpera: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return !!agent.match(/opera/i);
    },

    // ** {{{ AC.Detector.isIE() }}} **
    //
    // Returns whether or not the user agent reports that it is IE.
    isIE: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return !!agent.match(/msie/i);
    },

    // ** {{{ AC.Detector.isIEStrict() }}} **
    //
    // Returns whether or not the is IE, and not another browser
    // masquerading as IE.
    isIEStrict: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return agent.match(/msie/i) && !this.isOpera(agent);
    },

    // ** {{{ AC.Detector.isFirefox() }}} **
    //
    // Returns whether or not the user agent is Firefox.
    isFirefox: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return !!agent.match(/firefox/i);
    },

    //deprecated, use isMobile
    isiPhone: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return this.isMobile(agent);
    },
	/*Returns an array with the version numbers*/
	iPhoneOSVersion: function(userAgent) {
		//OSString: Mozilla/5.0 (iPhone; U; CPU iPhone OS 2_0 like Mac OS X; en-us) AppleWebKit/525.18.1 (KHTML, like Gecko) Version/3.1.1 Mobile/XXXXX Safari/525.20
        var agent = userAgent || this.getAgent(),
			isMobile = this.isMobile(agent),
			OSString, OSStringParts, version;
		if(isMobile) {
			//Now looks at user agent
			var OSString = agent.match(/.*CPU ([\w|\s]+) like/i);
			if(OSString && OSString[1]) {
				OSStringParts = OSString[1].split(" ");
				version = OSStringParts[2].split("_");
				return version;
			}
			else {
				//iPhone running  : Mozilla/5.0 (iPod; U; CPU iPhone OS 2_2_1 like Mac OS X; pl-pl) AppleWebKit/525.18.1 (KHTML, like Gecko) Version/3.1.1 Mobile/5H11 Safari/525.20
				//iPod touch running iPhone OS 1.1.3 user agent string: Mozilla/5.0 (iPod; U; CPU like Mac OS X; en) AppleWebKit/420.1 (KHTML, like Gecko) Version/3.0 Mobile/4A93 Safari/419.3
				//iPhone running iPhone OS 1.0 user agent string: Mozilla/5.0 (iPhone; U; CPU like Mac OS X; en) AppleWebKit/420+ (KHTML, like Gecko) Version/3.0 Mobile/1A543 Safari/419.3

				return [1];
			}

		}
		else return null;

	},
	
	// ** {{{ AC.Detector.isiPad() }}} **
	//
	// Returns whether or not the platform is an iPad
    isiPad: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
		//iPad running: Mozilla/5.0 (iPad; U; CPU OS 3_2 like Mac OS X; en-us) AppleWebKit/531.21.10 (KHTML, like Gecko) Version/4.0.4 Mobile/7B334b Safari/531.21.10
        return this.isWebKit(agent) && agent.match(/ipad/i);
    },

	// ** {{{ AC.Detector.isiPad() }}} **
	//
	// Returns whether or not the platform is an iPad
    isiPad: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
		//iPad running: Mozilla/5.0 (iPad; U; CPU OS 3_2 like Mac OS X; en-us) AppleWebKit/531.21.10 (KHTML, like Gecko) Version/4.0.4 Mobile/7B334b Safari/531.21.10
        return this.isWebKit(agent) && agent.match(/ipad/i);
    },

    // ** {{{ AC.Detector.isMobile() }}} **
    //
    // Returns whether or not the platform is an iPhone or an iPhone touch.
    isMobile: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return this.isWebKit(agent) && (agent.match(/Mobile/i) && !this.isiPad(agent));
    },

    // ** {{{ AC.Detector.isiTunesOK() }}} **
    //
    // Returns whether or not the platform is compatible with iTunes.
    isiTunesOK: function(userAgent)
    {
        var agent = userAgent || this.getAgent();
        return this.isMac(agent) || this.isWin2k(agent);
    },

    // ** {{{ AC.Detector.isQTInstalled() }}} **
    //
    // Returns whether or not the QuickTime plugin is installed.
    //
    // Note that the iPhone is not regisetered by this, but is typically
    // treated as having QuickTime.

    _isQTInstalled: undefined,

    isQTInstalled: function()
    {

		if(this._isQTInstalled === undefined) {
	        var qtInstalled = false;

	        if (navigator.plugins && navigator.plugins.length) {

	            for(var i=0; i < navigator.plugins.length; i++ ) {
	                var plugin = navigator.plugins[i];

	                if (plugin.name.indexOf("QuickTime") > -1) {
	                    qtInstalled = true;
	                }
	            }
	        } else if (typeof(execScript) != 'undefined') {
	            qtObj = false; //global variable written to by vbscript for ie
	            execScript('on error resume next: qtObj = IsObject(CreateObject("QuickTimeCheckObject.QuickTimeCheck.1"))','VBScript');
	            qtInstalled = qtObj;
	        }

			this._isQTInstalled = qtInstalled;
		}
		return this._isQTInstalled;
    },

    // ** {{{ AC.Detector.getQTVersion() }}} **
    //
    // Returns the version of QuickTime installed.
    //
    getQTVersion: function()
    {
        var version = "0";

        if (navigator.plugins && navigator.plugins.length) {
            for (var i = 0; i < navigator.plugins.length; i++) {

                var plugin = navigator.plugins[i];

                //Match: QuickTime Plugin X.Y.Z
                var match = plugin.name.match(/quicktime\D*([\.\d]*)/i);
                if (match && match[1]) {
                    version = match[1];
                }
            }
        } else if (typeof(execScript) != 'undefined') {
            ieQTVersion=null;

            execScript('on error resume next: ieQTVersion = CreateObject("QuickTimeCheckObject.QuickTimeCheck.1").QuickTimeVersion','VBScript');

            if(ieQTVersion){
                // ieQTVersion is comes back as '76208000' when 7.6.2 is installed.
                version = ieQTVersion.toString(16);
                version = [version.charAt(0), version.charAt(1), version.charAt(2)].join('.');
            }
        }

        return version;
    },

    // ** {{{ AC.Detector.isQTCompatible(required, actual) }}} **
    //
    // Returns whether or not the {{{actual}}} version is considered
    // compatible with the {{{required}}} version.
    //
    // Note that versions are expressed as dot-delimited strings.
    //
    // {{{required}}}: The minimum version required
    //
    // {{{actual}}}: The actual version available
    //
    isQTCompatible: function(required, actual)
    {
        function areCompatible(required, actual) {

            var requiredValue = parseInt(required[0], 10);
            if (isNaN(requiredValue)) {
                requiredValue = 0;
            }

            var actualValue = parseInt(actual[0], 10);
            if (isNaN(actualValue)) {
                actualValue = 0;
            }

            if (requiredValue === actualValue) {
                if (required.length > 1) {
                    return areCompatible(required.slice(1), actual.slice(1));
                } else {
                    return true;
                }
            } else if (requiredValue < actualValue) {
                return true;
            } else {
                return false;
            }
        }

        var expectedVersion = required.split(/\./);
        var actualVersion = actual ? actual.split(/\./) : this.getQTVersion().split(/\./);

        return areCompatible(expectedVersion, actualVersion);
    },

    // ** {{{ AC.Detector.isValidQTAvailable(required) }}} **
    //
    // Returns whether or not the QuickTime plugin installed is compatible
    // with the {{{required}}} version.
    //
    // {{{required}}}: The minimum version required
    //
    isValidQTAvailable: function(required)
    {
        return this.isQTInstalled() && this.isQTCompatible(required);
    },

	// ** {{{ AC.Detector.isSBVDPAvailable(required) }}} **
    //
    // Returns whether or not the SBVDP plugin installed is compatible
    // with the {{{required}}} version.
    //
    // {{{required}}}: The minimum version required
	// *note* default should be 9.0.115 for h.264 encoded movies
    //
	isSBVDPAvailable: function(required) {
        return false;
	}

};


