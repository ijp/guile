/* test-loose-ends.c
 *
 * Test items of the Guile C API that aren't covered by any other tests.
 */

/* Copyright (C) 2009 Free Software Foundation, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301 USA
 */

#if HAVE_CONFIG_H
# include <config.h>
#endif

#include <libguile.h>

#include <stdio.h>
#include <assert.h>
#include <string.h>

#ifdef HAVE_INTTYPES_H
# include <inttypes.h>
#endif

static void
test_scm_from_locale_keywordn ()
{
  SCM kw = scm_from_locale_keywordn ("thusly", 4);
  assert (scm_is_true (scm_keyword_p (kw)));
}

static void
tests (void *data, int argc, char **argv)
{
  test_scm_from_locale_keywordn ();
}

int
main (int argc, char *argv[])
{
  scm_boot_guile (argc, argv, tests, NULL);
  return 0;
}
