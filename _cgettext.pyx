import codecs
import gettext
from gettext import c2py


# These definitions live in Cython's stdlib in later versions, but define them
# directly here for compatability's sake.  These are all taken straight from
# Cython.
ctypedef unsigned int u32

cdef extern from *:
    object PyUnicode_DecodeUTF8(char *s, Py_ssize_t size, char *errors)
    object PyUnicode_DecodeASCII(char *s, Py_ssize_t size, char *errors)


# .mo magic numbers
cdef u32 LE_MAGIC = 0x950412de
cdef u32 BE_MAGIC = 0xde120495


# Helper functions
cdef inline u32 read_u32(char* buf, int start, bint use_le):
    """Convert four bytes to a 32-bit unsigned integer.

    LE and BE are handled by a single function so it can be inlined.  LE is the
    faster path (I think?) because, hey, who isn't on LE?
    """
    cdef unsigned char* ubuf = <unsigned char*>buf
    cdef u32 ret = (
        (ubuf[start + 3] << 24) |
        (ubuf[start + 2] << 16) |
        (ubuf[start + 1] <<  8) |
        (ubuf[start + 0] << 0)
    )

    cdef unsigned char* swap
    if not use_le:
        swap = <unsigned char*> &ret
        swap[0] ^= swap[3]
        swap[3] ^= swap[0]
        swap[0] ^= swap[3]

        swap[1] ^= swap[2]
        swap[2] ^= swap[1]
        swap[1] ^= swap[2]

    return ret


# Wrappers for using Python's C-level decoding directly
cdef unicode c_decode_ascii(char* string, int start, int end, object decoder):
    return PyUnicode_DecodeASCII(&string[start], end - start, 'strict')

cdef unicode c_decode_utf8(char* string, int start, int end, object decoder):
    return PyUnicode_DecodeUTF8(&string[start], end - start, 'strict')

cdef unicode c_decode_other(char* string, int start, int end, object decoder):
    # This is the fallback for any other encoding, which just calls the
    # Python-level decoder function
    return decoder(<bytes>string[start:end], 'strict')[0]

ctypedef unicode (*cdecoder)(char*, int, int, object)


def _default_plural(int n):
    """Default plural-mapping function.  Describes the "Germanic" plural, i.e.
    the one English uses, with only singular and plural.
    """
    return int(n != 1)


def c_parse(fp):
    """C port of gettext.GNUTranslations._parse, with the hard parts made to be
    as C-able as possible.
    """
    # Return values
    cdef dict catalog = {}
    cdef dict metadata = {}
    cdef object plural = _default_plural

    # Read the file!
    filename = getattr3(fp, 'name', '')
    cdef bytes pybuf = fp.read()
    cdef unsigned int buflen = len(pybuf)
    cdef char* buf = pybuf

    # Parse the .mo file header, which consists of 5 little endian 32
    # bit words.
    # Are we big endian or little endian?
    cdef u32 magic = read_u32(buf, 0, 1)
    cdef bint use_le
    if magic == LE_MAGIC:
        use_le = 1
    elif magic == BE_MAGIC:
        use_le = 0
    else:
        raise IOError(0, 'Bad magic number', filename)

    cdef u32 version = read_u32(buf, 4, use_le)
    cdef u32 msgcount = read_u32(buf, 8, use_le)
    cdef u32 masteridx = read_u32(buf, 12, use_le)
    cdef u32 transidx = read_u32(buf, 16, use_le)

    # Length of each message and its translation
    cdef u32 mlen, moff, mend, tlen, toff, tend
    # Pointers used to point at each message and its translation
    cdef char* cmsg
    cdef char* ctmsg

    # Temporary values used while parsing a message
    cdef char* cptr
    cdef bint is_plural
    cdef int msgid_len
    cdef int n
    cdef int pos
    cdef int start
    cdef unicode msgid

    # Temporary values used while parsing a header -- these are Python types
    # becuase there's a lot of splitting involved
    cdef bytes unparsed_header
    cdef bytes key
    cdef bytes lastkey
    cdef bytes value
    cdef bytes item

    # Character set; need the name as a return value, and the combination of C
    # function pointer and Python codec function allow for using the C API
    # directly in the common cases of ASCII and UTF-8.
    cdef str charset = 'ascii'
    cdef cdecoder decode = c_decode_ascii
    cdef codec = None

    # Now put all messages from the .mo file buffer into the catalog
    # dictionary.
    for _ in range(msgcount):
        mlen = read_u32(buf, masteridx, use_le)
        moff = read_u32(buf, masteridx + 4, use_le)
        mend = moff + mlen
        tlen = read_u32(buf, transidx, use_le)
        toff = read_u32(buf, transidx + 4, use_le)
        tend = toff + tlen
        if mend < buflen and tend < buflen:
            cmsg = &buf[moff]
            ctmsg = &buf[toff]
        else:
            raise IOError(0, 'File is corrupt', filename)

        # See if we're looking at GNU .mo conventions for metadata
        if mlen == 0:
            # Catalog description
            lastkey = key = None
            unparsed_header = ctmsg
            for item in unparsed_header.splitlines():
                item = item.strip()
                if not item:
                    continue
                if b':' in item:
                    key, value = item.split(b':', 1)
                    key = key.strip().lower()
                    value = value.strip()
                    metadata[key] = value
                    lastkey = key
                elif lastkey:
                    metadata[lastkey] += b'\n' + item

                if key == b'content-type':
                    charset = value.split(b'charset=')[1]
                    codec = codecs.getdecoder(charset)
                    if charset.lower() == 'ascii':
                        decode = c_decode_ascii
                    elif charset.lower() in ('utf8', 'utf-8'):
                        decode = c_decode_utf8
                    else:
                        decode = c_decode_other
                elif key == b'plural-forms':
                    value = value.split(';')[1]
                    plural = value.split(b'plural=')[1]
                    plural = c2py(plural)

        # Note: we unconditionally convert both msgids and msgstrs to
        # Unicode using the character encoding specified in the charset
        # parameter of the Content-Type header.  The gettext documentation
        # strongly encourages msgids to be us-ascii, but some appliations
        # require alternative encodings (e.g. Zope's ZCML and ZPT).  For
        # traditional gettext applications, the msgid conversion will
        # cause no problems since us-ascii should always be a subset of
        # the charset encoding.  We may want to fall back to 8-bit msgids
        # if the Unicode conversion fails.

        # Some things to note about this code.  The format for a plural is:
        # msgid1\0msgid2\0 ... trans1\0trans2\0trans3\0...\0
        # So we scan through the raw char* looking for a NUL.  If it appears at
        # the end of the string (given by the length), it must be singular.
        # Otherwise, it must be plural, and we split the translations on NUL
        # too.  Conveniently, msgid2 is never used.
        cptr = cmsg
        is_plural = 0
        msgid_len = mlen
        for pos in range(mlen):
            if cptr[0] == b'\x00':
                is_plural = 1
                msgid_len = pos
            cptr += 1
        msgid = decode(cmsg, 0, msgid_len, codec)

        if is_plural:
            # Need to split the translation string into multiple chunks,
            # delimited by NULs
            n = 0
            start = 0
            cptr = ctmsg
            for pos in range(tlen):
                if ctmsg[pos] == b'\x00':
                    catalog[msgid, n] = decode(cptr, start, pos, codec)
                    # Set the start pointer to /after/ the nul byte
                    start = pos + 1
                    n += 1
            # Grab the trailing one, as `tlen` doesn't include the final NUL
            catalog[msgid, n] = decode(cptr, start, tlen, codec)
        else:
            # Singular; just use the entire translation
            catalog[msgid] = decode(ctmsg, 0, tlen, codec)

        # advance to next entry in the seek tables
        masteridx += 8
        transidx += 8

    return charset, metadata, catalog, plural
