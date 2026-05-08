// eslint-disable-next-line
// @ts-nocheck
(function () {
	var rm;

	window._getLocation = function () {
		return window.location;
	};

	window.updateTree = function () {
		window.mainLayout.observer.notify('UpdateTOC');
	};

	function checkCachingMechanism() {
		var checkCachingMechanismUrl =
			aras.getScriptsURL() + 'CheckCachingMechanism.aspx';
		var requestSettings = {
			url: checkCachingMechanismUrl,
			restMethod: 'GET',
			async: true
		};

		var firstRequestResponse;

		return ArasModules.soap('', requestSettings)
			.then(function (responseText) {
				firstRequestResponse = responseText;

				return ArasModules.soap('', requestSettings);
			})
			.then(function (secondRequestResponse) {
				return firstRequestResponse === secondRequestResponse;
			});
	}

	function disableFileDrop() {
		// disable drop file by all iframes in the window
		var prevent = function (e) {
			e.preventDefault();
		};
		// disable drag&drop for Innovator iframes
		// to prevent an attempt to open a dropped file in a browser
		// so as not to replace the Innovator itself
		[].forEach.call(
			window.document.querySelectorAll('#tz, #deepLinking'),
			function (elm) {
				elm.contentWindow.addEventListener('drop', prevent);
				elm.contentWindow.addEventListener('dragover', prevent);
			}
		);

		// disable drop file by window
		window.addEventListener('drop', prevent);
		window.addEventListener('dragover', prevent);
	}

	window.onLogoutCommand = function (event) {
		if (event) {
			event.preventDefault();
		}

		return new Promise(function (resolve) {
			if (
				!aras.getCommonPropertyValue('exitInProgress') &&
				window.aras.isDirtyItems()
			) {
				aras.dirtyItemsHandler();
				resolve();
			} else {
				// Close opened windows to have the same behaviour as in onpagehide handler.
				// Additionally this call helps to avoid warning that may be shown
				// in onbeforeunload when active tab is not home tab.
				aras.setCommonPropertyValue('exitInProgress', true);

				aras.getOpenedWindowsCount(true);

				setTimeout(function () {
					// Logout at the first from Innovator.
					aras
						.logout()
						// And only then from OAuthServer.
						// Call to logout will trigger current document unloading.
						.then(function () {
							const url = new URL(window._getLocation().href);
							url.searchParams.delete('StartItem');
							aras.OAuthClient.logout({
								state: {
									returnUrl: url.toString()
								}
							});
						})
						.then(resolve);
					// We should reset onpagehide handler because all necessary logout logic done here.
					window.onpagehide = null;
				}, 0);
			}
		});
	};

	window.defineWorkElement = function () {
		Object.defineProperty(window, 'work', {
			configurable: true,
			get: function () {
				const arasTabsObj = window.document.querySelector(
					'aras-header-tabs.content-block__main-tabs_active'
				);
				const selectedTabId = arasTabsObj.selectedTab;

				if (!selectedTabId) {
					return window;
				}

				let tabContentWindow;
				const selectedTab = arasTabsObj.data.get(selectedTabId);
				const parentTabId = selectedTab && selectedTab.parentTab;
				if (
					selectedTabId.startsWith('search_') &&
					window.document.getElementById(selectedTabId)
				) {
					tabContentWindow =
						window.document.getElementById(selectedTabId).contentWindow;
				} else if (
					parentTabId &&
					parentTabId.startsWith('search_') &&
					window.document.getElementById(parentTabId)
				) {
					tabContentWindow =
						window.document.getElementById(parentTabId).contentWindow;
				} else if (
					selectedTab &&
					window.document.getElementById(selectedTabId)
				) {
					tabContentWindow =
						window.document.getElementById(selectedTabId).contentWindow;
				}

				return tabContentWindow || window;
			}
		});
	};

	/**
	 * Initialize main window. Called from onSuccessfulLogin function of login.aspx.
	 *
	 * @returns {boolean}
	 */
	window.initialize = function () {
		fixDojoSettings();

		const defaultLanguageCode = aras.getSessionContextLanguageCode();
		const languages = [];
		const { xml } = window.ArasModules;
		xml
			.selectNodes(aras.getLanguagesResultNd(), 'Item[@type="Language"]')
			?.forEach((language) => {
				const codePropertyNode = xml.selectSingleNode(language, 'code');
				const namePropertyNode = xml.selectSingleNode(language, 'name');
				const code = codePropertyNode?.textContent;
				const name = namePropertyNode?.textContent;
				if (!code || !name) {
					return;
				}

				languages.push({ code, name });
			});

		const payload = { defaultLanguageCode, languages };
		window.store.boundActionCreators.setSystemSettings(payload);

		rm = new ResourceManager(
			new Solution('core'),
			'ui_resources.xml',
			defaultLanguageCode
		);

		var userNd = aras.getLoggedUserItem(true);
		if (!userNd) {
			window.onbeforeunload = '';
			window.close();
			return false;
		}
		if (!document.frames) {
			document.frames = [];
		}

		aras.getPreferenceItemProperty(
			'Core_GlobalLayout',
			null,
			'core_append_items'
		);
		aras.getPreferenceItemProperty(
			'SSVC_Preferences',
			null,
			'default_bookmark'
		);

		aras.commonProperties.serverVersion =
			window.arasMainWindowInfo.serverVersion;

		var phoneHomeCall = new PhoneHomeCall(aras);
		phoneHomeCall.tryGetUpdateInfo().catch(function(){});
		phoneHomeCall.tryStoreStatistics().catch(function(){});

		defineWorkElement();
		checkCachingMechanism().then(function (isCachingMechanismWork) {
			if (!isCachingMechanismWork) {
				aras.AlertError(rm.getString('setup.cache_is_disabled'));
			}
		});

		aras.UpdateFeatureTreeIfNeed();

		document.corporateToLocalOffset = aras.getCorporateToLocalOffset();
		PopulateDocByLabels();

		disableFileDrop();

		window.arasTabs = document.getElementById('main-tab');

		const {
			favoriteItems,
			favoriteItemTypes,
			favoriteSearches,
			favoriteGridLayouts
		} = window.arasMainWindowInfo;
		const favoriteItemJson = [
			favoriteGridLayouts,
			favoriteItems,
			favoriteItemTypes,
			favoriteSearches
		];

		const favoriteItemsList = favoriteItemJson.reduce(
			(acc, item) => (item ? [...acc, ...JSON.parse(item)] : acc),
			[]
		);
		window.store.boundActionCreators.setFavorites(favoriteItemsList);

		window.runFunctionInContextTopWindow = (cb, ...arg) =>
			setTimeout(() => cb(...arg), 0);
		return true;
	};
})();
