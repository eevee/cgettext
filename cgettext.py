try:
    from _cgettext import c_parse
except ImportError:
    # No C module available; just re-export the builtin
    from gettext import GNUTranslations
else:
    import gettext


    class GNUTranslations(gettext.GNUTranslations):
        def _parse(self, fp):
            charset, metadata, catalog, plural = c_parse(fp)
            self._charset = charset
            self._info = metadata
            self._catalog = catalog
            self.plural = plural


__all__ = ['GNUTranslations']
