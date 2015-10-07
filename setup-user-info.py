#!/usr/bin/env python

import sys
import subprocess
from keystoneclient.auth.identity import v2
from keystoneclient import session
from novaclient.client import Client
import sys
import pwd
import getopt
import os
import re
import xmlrpclib
from M2Crypto import X509
import os.path
#import keystoneclient
#import novaclient
import traceback

with open('/root/setup/settings','r') as file:
    content = file.read()
    pass
exec(content)

with open('/root/setup/admin-openrc.py','r') as file:
    content = file.read()
    pass
exec(content)

dirname = os.path.abspath(os.path.dirname(sys.argv[0]))
execfile("%s/test-common.py" % (dirname,))

#
# Convert the certificate into a credential.
#
params = {}
rval,response = do_method("", "GetCredential", params)
if rval:
    Fatal("Could not get my credential")
    pass
mycredential = response["value"]

params["credential"] = mycredential
rval,response = do_method("", "GetSSHKeys", params)
if rval:
    Fatal("Could not get ssh keys")
    pass

#
# This is really, really ugly.  So, keystone and nova don't offer us a way to
# upload keypairs on behalf of another user.  Recall, we're using the adminapi
# account to do all this setup, because we don't know the admin password.  So,
# the below code adds all the keys as 'adminapi', then we dump the sql, do some
# sed magic on it to get rid of the primary key and change the user_id to the
# real admin user_id, then we insert those rows, then we cleanup the lint.  By
# doing it this way, we eliminate our dependency on the SQL format and column
# names and semantics.  We make two assumptions: 1) that there is only one field
# that has integer values, and 2) the only field that is an exception to #1 is
# called 'deleted' and we just set those all to 0 after we jack the whacked sql
# in.  Ugh, it's worse than I hoped, but whatever.
#
# This is one of the sickest one-liners I've ever come up with.
#

url = 'http://%s:5000/v2.0' % (CONTROLLER,)
auth = v2.Password(auth_url=url,username=ADMIN_API,password=ADMIN_API_PASS,tenant_name='admin')
sess = session.Session(auth=auth)
nova = Client(2,session=sess)

for userdict in response['value']:
    urn = userdict['urn']
    login = userdict['login']
    for keydict in userdict['keys']:
        if not keydict.has_key('type') or keydict['type'] != 'ssh':
            continue
        
        key = keydict['key']
            
        posn = key.rindex(' ')
        name = key[posn+1:]
        rname = login + "-"
        for c in name:
            if c.isalpha():
                rname += c
            else:
                rname += 'X'
            pass
        
        try:
            nova.keypairs.create(rname,key)
        except:
            traceback.print_exc()
        pass
    pass

#
# Ok, do the sick hack...
#
os_cred_stuff = "--os-username %s --os-password %s --os-tenant-name %s --os-auth-url %s" % (OS_USERNAME,OS_PASSWORD,OS_TENANT_NAME,OS_AUTH_URL,)
cmd = 'export AAUID="`keystone %s user-list | awk \'/ adminapi / {print $2}\'`" ; export AUID="`keystone %s user-list | awk \'/ admin / {print $2}\'`" ; mysqldump -u nova --password=%s nova -t key_pairs --skip-comments --quote-names --no-create-info --no-create-db --complete-insert --compact | sed -e \'s/,[0-9]*,/,NULL,/gi\' | sed -e "s/,\'${AAUID}\',/,\'${AUID}\',/gi" | mysql -u nova --password=%s nova ; echo "update key_pairs set deleted=0 where user_id=\'${AUID}\'" | mysql -u nova --password=%s nova' % (os_cred_stuff,os_cred_stuff,NOVA_DBPASS,NOVA_DBPASS,NOVA_DBPASS,)
#cmd = 'export OS_PASSWORD="%s" ; export OS_AUTH_URL="%s" ; export OS_USERNAME="%s" ; export OS_TENANT_NAME="%s" ; export AAUID="`keystone user-list | awk \'/ adminapi / {print $2}\'`" ; export AUID="`keystone user-list | awk \'/ admin / {print $2}\'`" ; mysqldump -u nova --password=%s nova -t key_pairs --skip-comments --quote-names --no-create-info --no-create-db --complete-insert --compact | sed -e \'s/,[0-9]*,/,NULL,/gi\' | sed -e "s/,\'${AAUID}\',/,\'${AUID}\',/gi" | mysql -u nova --password=%s nova ; echo "update key_pairs set deleted=0 where user_id=\'${AUID}\'" | mysql -u nova --password=%s nova' % (OS_PASSWORD,OS_AUTH_URL,OS_USERNAME,OS_PASSWORD,NOVA_DBPASS,NOVA_DBPASS,NOVA_DBPASS,)
print "Running adminapi -> admin key import: %s..." % (cmd,)
os.system(cmd)

sys.exit(0)
