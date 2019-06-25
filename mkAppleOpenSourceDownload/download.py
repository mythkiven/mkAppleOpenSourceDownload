#-*- coding:utf-8 -*-
import re
import sys
import os
import requests
from bs4 import BeautifulSoup
import os

currentPath = os.path.abspath('.')

class mkADownload():
    def mkdir(self,path):
        isExists = os.path.exists(os.path.join(currentPath, path))
        if not isExists:
            os.makedirs(os.path.join(currentPath, path))
            os.chdir(os.path.join(currentPath, path))
            return True
        else:
            return False
    
    def download(self,word,path):
        print('>> Search keyword: '+word+'..')
        baseuri = 'https://opensource.apple.com/tarballs/'
        uri = baseuri
        result = requests.get(baseuri,timeout=120)
        if len(result.text) < 100 or result.status_code != 200:
            print('ERROR!!!Please contact the author (https://github.com/mythkiven/mkAppleOpenSourceDownload) to fix the problem!')
            return
        
        Soup = BeautifulSoup(result.text, 'lxml')
        all_td = Soup.find_all('td', valign='top')
        if(len(all_td)==0):
            print('ERROR!!!Please contact the author (https://github.com/mythkiven/mkAppleOpenSourceDownload) to fix the problem!')
            return
        out = True
        for td in all_td:
            href = td.a['href']
            if(href == './../'):
                continue
            title = href.replace('/','')
            word = word.replace(' ','').lower()
            if(word in title.lower()):
                word = title
                out = True
                print('>> Match to resource:['+title+'], will download')
                break
            else:
                out = False
        if(not out):
            print('Not found, please confirm that the word you entered is correct')
            return
        uri = baseuri +  word + '/'
        page = requests.get(uri,timeout=120)
        if len(page.text) < 100 or page.status_code != 200:
            print('ERROR!!!Please contact the author (https://github.com/mythkiven/mkAppleOpenSourceDownload) to fix the problem!')
            return

        Soup = BeautifulSoup(page.text, 'lxml')
        all_td = Soup.find_all('td', valign='top')
        if(len(all_td)==0):
            print('ERROR!!!Please contact the author (https://github.com/mythkiven/mkAppleOpenSourceDownload) to fix the problem!')
            return
        for td in all_td:
            href = td.a['href']
            if(href == './../'):
                continue
            print('>>> Download : '+href)
            title = href
            href = uri + href
            self.mkdir(word)
            self.downloadTarWithURL(href, os.path.join(currentPath,word+'/'+title))
        print('The file is saved in :'+os.path.join(currentPath,word+'/'))
    def downloadTarWithURL(self,uri,path):
        result = requests.get(uri,timeout=120)
        f = open(path, 'wb')
        f.write(result.content)
        f.close()


