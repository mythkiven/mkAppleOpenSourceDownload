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
        path = path.replace('~/', os.path.expanduser('~')+'/')
        isExists = os.path.exists(path)
        if not isExists:
            try:
                os.makedirs(path)
                return path
            except:
                os.makedirs(os.path.join(currentPath, path))
                return os.path.join(currentPath, path)
        else:
            return path
    def handleword(self,word):
        if(word.lower() =='corefoundation'):
            return 'CF'
        return word

    def download(self,word,path):
        word = self.handleword(word)
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
        path = os.path.join(path,word)
        if(self.mkdir(path)):
            path = self.mkdir(path)
            os.chdir(self.mkdir(path))
        else:
            print('ERROR!!! Please use the full path')

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

        print('>> --> Download from  "https://opensource.apple.com/" <--')

        for td in all_td:
            href = td.a['href']
            if(href == './../'):
                continue
            print('>>> Download : '+href)
            title = href
            href = uri + href
            self.downloadTarWithURL(href , os.path.join(path,title))
        print('The file is saved in :' + os.path.join(path,title))
    def downloadTarWithURL(self,uri,path):
        result = requests.get(uri,timeout=120)
        f = open(path, 'wb')
        f.write(result.content)
        f.close()


