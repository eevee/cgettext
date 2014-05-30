"""Run the built-in Python test suite, with our class monkeypatched in."""
import gettext
import unittest
import test.test_gettext

import cgettext


# Monkeypatch!  test_gettext doesn't import this class directly.
gettext.GNUTranslations = cgettext.GNUTranslations

unittest.main(test.test_gettext)
