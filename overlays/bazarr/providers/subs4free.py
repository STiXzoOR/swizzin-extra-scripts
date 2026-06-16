# -*- coding: utf-8 -*-
from __future__ import absolute_import
import io
import logging
import os
import random

import rarfile
import re
import zipfile

from subzero.language import Language
from guessit import guessit
from subliminal_patch.http import RetryingCFSession
from subliminal_patch.pitcher import pitchers

from subliminal.providers import ParserBeautifulSoup, Provider
from subliminal import __short_version__
from subliminal.cache import SHOW_EXPIRATION_TIME, region
from subliminal.score import get_equivalent_release_groups
from subliminal.subtitle import SUBTITLE_EXTENSIONS, Subtitle, fix_line_ending
from subliminal.utils import sanitize, sanitize_release_group
from subliminal.video import Movie
from subliminal_patch.subtitle import guess_matches

logger = logging.getLogger(__name__)

year_re = re.compile(r'^\((\d{4})\)$')


class Subs4FreeSubtitle(Subtitle):
    """Subs4Free Subtitle."""
    provider_name = 'subs4free'

    def __init__(self, language, page_link, title, year, version, download_link, uploader):
        super(Subs4FreeSubtitle, self).__init__(language, page_link=page_link)
        self.title = title
        self.year = year
        self.version = version
        self.release_info = version
        self.download_link = download_link
        self.uploader = uploader
        self.hearing_impaired = None
        self.encoding = 'utf8'
        self.matches = set()

    @property
    def id(self):
        return self.download_link

    def get_matches(self, video):
        # movie
        if isinstance(video, Movie):
            # title
            if video.title and (sanitize(self.title) in (
                    sanitize(name) for name in [video.title] + video.alternative_titles)):
                self.matches.add('title')
            # year
            if video.year and self.year == video.year:
                self.matches.add('year')

        # release_group
        if (video.release_group and self.version and
                any(r in sanitize_release_group(self.version)
                    for r in get_equivalent_release_groups(sanitize_release_group(video.release_group)))):
            self.matches.add('release_group')
        # other properties
        self.matches |= guess_matches(video, guessit(self.version, {'type': 'movie'}), partial=True)

        return self.matches


class Subs4FreeProvider(Provider):
    """Subs4Free Provider."""
    languages = {Language(l) for l in ['ell', 'eng']}
    video_types = (Movie,)
    server_url = 'https://www.subs4free.info'
    download_url = '/getSub.php'
    search_url = '/search_report.php?search={}&searchType=1'
    anti_block_1 = 'https://images.subs4free.info/favicon.ico'
    anti_block_2 = 'https://www.subs4series.com/includes/anti-block-layover.php?launch=1'
    anti_block_3 = 'https://www.subs4series.com/includes/anti-block.php'
    subtitle_class = Subs4FreeSubtitle

    def __init__(self):
        self.session = None

    def initialize(self):
        self.session = RetryingCFSession()
        from .utils import FIRST_THOUSAND_OR_SO_USER_AGENTS as AGENT_LIST
        self.session.headers['User-Agent'] = AGENT_LIST[random.randint(0, len(AGENT_LIST) - 1)]

    def terminate(self):
        self.session.close()

    def get_show_links(self, title, year=None):
        """Get the matching show links for `title` and `year`.

        First search in the result of :meth:`_get_show_suggestions`.

        :param title: show title.
        :param year: year of the show, if any.
        :type year: int
        :return: the show links, if found.
        :rtype: list of str

        """
        title = sanitize(title)
        suggestions = self._get_suggestions(title)

        show_links = []
        for suggestion in suggestions:
            show_title = sanitize(suggestion['title'])

            if show_title == title or (year and show_title == '{title} {year:d}'.format(title=title, year=year)):
                logger.debug('Getting show id')
                show_links.append(suggestion['link'].lstrip('/'))

        return show_links

    @region.cache_on_arguments(expiration_time=SHOW_EXPIRATION_TIME, should_cache_fn=lambda value: value)
    def _get_suggestions(self, title):
        """Search the show or movie id from the `title` and `year`.

        :param str title: title of the show.
        :return: the show suggestions found.
        :rtype: list of dict

        """
        # make the search
        logger.info('Searching show ids with %r', title)
        r = self.session.get(self.server_url + self.search_url.format(title),
                             headers={'Referer': self.server_url}, timeout=10)
        r.raise_for_status()

        if not r.content:
            logger.debug('No data returned from provider')
            return []

        soup = ParserBeautifulSoup(r.content, ['html.parser'])
        # Site redesigned: dropdown now uses onChange instead of name attribute
        suggestions = [{'link': l.attrs['value'], 'title': l.text}
                       for l in soup.select('select[onChange*="MM_jumpMenu"] > option[value]')
                       if l.attrs.get('value', '').startswith('/')]
        logger.debug('Found suggestions: %r', suggestions)

        return suggestions

    def query(self, movie_id, title, year):
        # get the season list of the show
        logger.info('Getting the subtitle list of show id %s', movie_id)
        if movie_id:
            page_link = self.server_url + '/' + movie_id
        else:
            page_link = self.server_url + self.search_url.format(' '.join([title, str(year)]))

        r = self.session.get(page_link, timeout=10)
        r.raise_for_status()

        if not r.content:
            logger.debug('No data returned from provider')
            return []

        soup = ParserBeautifulSoup(r.content, ['html.parser'])

        # Extract year and title from redesigned layout (DIV-based)
        year = None
        show_title = None
        h2_element = soup.select_one('div.latest-left h2') or soup.select_one('div.latest-page-heading h2')
        if h2_element:
            year_match = re.search(r'\((\d{4})\)', h2_element.get_text())
            if year_match:
                year = int(year_match.group(1))
            title_u = h2_element.find('u')
            show_title = title_u.string.strip() if title_u and title_u.string else None

        subtitles = []
        # loop over subtitle rows
        for subs_tag in soup.select('.movie-details'):
            try:
                # Version from the heading link span
                version_el = subs_tag.select_one('a.movie-heading span')
                version = version_el.text if version_el else subs_tag.find('span').text

                # Download link (subtitle detail page)
                link_el = subs_tag.select_one('a.movie-heading')
                if not link_el:
                    continue
                download_link = self.server_url + link_el['href']

                # Uploader from movie-info paragraph
                uploader_el = subs_tag.select_one('.movie-info > p a')
                uploader = uploader_el.text if uploader_el else 'Unknown'

                # Language from sprite class (e.g. 'elgif' -> 'el', 'engif' -> 'en')
                language_code = 'el'
                sprite_el = subs_tag.select_one('.sprite')
                if sprite_el:
                    for cls in sprite_el.get('class', []):
                        if 'gif' in cls and cls != 'sprite':
                            language_code = cls.replace('gif', '')
                            break
                language = Language.fromietf(language_code)

                subtitle = self.subtitle_class(language, page_link, show_title, year, version, download_link, uploader)

                logger.debug('Found subtitle {!r}'.format(subtitle))
                subtitles.append(subtitle)
            except Exception as e:
                logger.debug('Subs4free: Failed to parse subtitle entry: %s', e)
                continue

        return subtitles

    def list_subtitles(self, video, languages):
        # lookup show_id
        titles = [video.title] + video.alternative_titles if isinstance(video, Movie) else []

        show_links = None
        for title in titles:
            show_links = self.get_show_links(title, video.year)
            if show_links:
                break

        subtitles = []
        # query for subtitles with the show_id
        if show_links:
            for show_link in show_links:
                subtitles += [s for s in self.query(show_link, video.title, video.year) if s.language in languages]
        else:
            subtitles += [s for s in self.query(None, sanitize(video.title), video.year) if s.language in languages]

        return subtitles

    def download_subtitle(self, subtitle):
        if isinstance(subtitle, Subs4FreeSubtitle):
            # download the subtitle
            logger.info('Downloading subtitle %r', subtitle)
            r = self.session.get(subtitle.download_link, headers={'Referer': subtitle.page_link}, timeout=10)
            r.raise_for_status()

            if not r.content:
                logger.debug('Unable to download subtitle. No data returned from provider')
                return

            soup = ParserBeautifulSoup(r.content, ['lxml', 'html.parser'])
            download_element = soup.select_one('input[name="id"]')
            subtitle_id = download_element['value'] if download_element else None

            if not subtitle_id:
                logger.debug('Unable to download subtitle. No download link found')
                return

            self.apply_anti_block(subtitle)

            data = {'id': subtitle_id}

            if 'g-recaptcha' in r.text:
                # reCAPTCHA v2: solve with pitcher (AntiCaptcha)
                site_key_match = re.search(r'data-sitekey="(.+?)"', r.text)
                if not site_key_match:
                    logger.warning('Subs4free: reCAPTCHA detected but no site key found')
                    return

                try:
                    pitcher = pitchers.get_pitcher()(
                        "Subs4free", subtitle.download_link, site_key_match.group(1),
                        user_agent=self.session.headers["User-Agent"],
                        cookies=self.session.cookies.get_dict(),
                        is_invisible=False)
                    result = pitcher.throw()
                except Exception as e:
                    logger.warning('Subs4free: Captcha solving not available: %s', e)
                    return

                if result:
                    data['g-recaptcha-response'] = result
                    data['my_recaptcha_challenge_field'] = 'manual_challenge'
                else:
                    logger.warning('Subs4free: Could not solve captcha')
                    return
            else:
                # Image button case: simulate click with random coordinates
                image_element = soup.select_one('input[type="image"]')
                if image_element:
                    width = int(str(image_element.get('width', '200')).strip('px'))
                    height = int(str(image_element.get('height', '58')).strip('px'))
                    data['x'] = random.randint(0, width)
                    data['y'] = random.randint(0, height)

            download_url = self.server_url + self.download_url
            r = self.session.post(download_url, data=data,
                                  headers={'Referer': subtitle.download_link}, timeout=10)
            r.raise_for_status()

            if not r.content:
                logger.debug('Unable to download subtitle. No data returned from provider')
                return

            archive = _get_archive(r.content)

            subtitle_content = _get_subtitle_from_archive(archive) if archive else r.content

            if subtitle_content:
                subtitle.content = fix_line_ending(subtitle_content)
            else:
                logger.debug('Could not extract subtitle from %r', archive)

    def apply_anti_block(self, subtitle):
        self.session.get(self.anti_block_1, headers={'Referer': subtitle.download_link}, timeout=10)
        self.session.get(self.anti_block_2, headers={'Referer': subtitle.download_link}, timeout=10)
        self.session.get(self.anti_block_3, headers={'Referer': subtitle.download_link}, timeout=10)


def _get_archive(content):
    # open the archive
    archive_stream = io.BytesIO(content)
    archive = None
    if rarfile.is_rarfile(archive_stream):
        logger.debug('Identified rar archive')
        archive = rarfile.RarFile(archive_stream)
    elif zipfile.is_zipfile(archive_stream):
        logger.debug('Identified zip archive')
        archive = zipfile.ZipFile(archive_stream)

    return archive


def _get_subtitle_from_archive(archive):
    for name in archive.namelist():
        # discard hidden files
        if os.path.split(name)[-1].startswith('.'):
            continue

        # discard non-subtitle files
        if not name.lower().endswith(SUBTITLE_EXTENSIONS):
            continue

        return archive.read(name)

    return None
