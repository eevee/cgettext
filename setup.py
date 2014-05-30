from distutils.core import setup
import platform


if platform.python_implementation() == 'CPython':
    from distutils.command.bdist import bdist as _bdist
    from distutils.command.sdist import sdist as _sdist
    from distutils.extension import Extension

    class sdist(_sdist):
        # sdist override that forces a Cython rebuild of _cgettext.c
        def run(self):
            from Cython.Build import cythonize
            cythonize(['_cgettext.pyx'])
            _sdist.run(self)

    class bdist(_bdist):
        # same story
        def run(self):
            from Cython.Build import cythonize
            cythonize(['_cgettext.pyx'])
            _bdist.run(self)

    cmdclass = dict(
        bdist=bdist,
        sdist=sdist,
    )
    ext_modules = [Extension('_cgettext', ['_cgettext.c'])]
else:
    cmdclass = dict()
    ext_modules = []


setup(
    name='cgettext',
    version='0.1',
    author='Eevee (Alex Munroe)',
    author_email='eevee.pypi@veekun.com',
    url='https://github.com/eevee/cgettext',
    license='MIT',

    cmdclass=cmdclass,
    ext_modules=ext_modules,
    py_modules=['cgettext'],
)
