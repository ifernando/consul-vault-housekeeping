import boto3
import requests
import smtplib
import email.utils
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import time

RESOURCE_TYPE='ec2'
consulvault_name = 'consulvault-'
consulHTTPPort='8500'
# /home/consul/consul_config/config.json  "ports"."http"


def gettagvalues(resource_type,region):
    client = boto3.client(
        resource_type,
        region_name=region
    )

    list_of_instance_ips = []
    response = client.describe_instances()
    for reservation in response["Reservations"]:
        for instance in reservation["Instances"]:
            try:
                for tag in instance["Tags"]:
                    if tag["Key"] == 'Name':
                        if consulvault_name in tag["Value"]:
                            list_of_instance_ips.append(instance.get('PrivateIpAddress'))
            except:
                status='died'

    print(list_of_instance_ips)
    return list_of_instance_ips

def getLeaderStatus(ip_list,Ip_from_list,port):
    request = "http://%s:%s/v1/status/leader" % (Ip_from_list,port)
    print("HTTP request: %s" % (request))
    http_response=''
    exist = False
    try:
        result_string =  requests.get(request)
        http_response = result_string.content[:-1]
        print("HTTP response: %s" % (result_string))
    except:
        print("Error In getting consul leader")

    for consul_instance_ip in ip_list:
        if consul_instance_ip in http_response:
            print ("Leader is %s" % (consul_instance_ip))
            exist = True

    if (exist):
        return True
    else:
        return False

def sendEmail(content):

    sender = 'roshane.ishara@gmail.com'
    sendername = 'Monitoring for Consul Cluster Leader'

    recipients  = ['<add-recepients>']


    smtp_username = "<add-ses-username>"
    smtp_password = "<add-ses-password>"
    host = "email-smtp.us-east-1.amazonaws.com"
    port = 465

    subject = 'Consul Leader Monitoring ('+ time.strftime("%c")+")"
    text = '\r\n'.join([
        "Consul Cluster Alerts",
        """This email was sent through the Amazon SES SMTP Interface using the Python smtplib package."""
    ])

    html = '\n'.join([
        "<html>",
        "<head></head>",
        "<body>",
        content
        ,
        "</body>",
        "</html>"
    ])

    msg = MIMEMultipart('alternative')
    msg['Subject'] = subject
    msg['From'] = email.utils.formataddr((sendername, sender))
    msg['To'] = ','.join(recipients)

    part1 = MIMEText(text, 'plain')
    part2 = MIMEText(html, 'html')

    msg.attach(part1)
    msg.attach(part2)

    try:
        server = smtplib.SMTP_SSL(host, port)
        server.ehlo()
        server.login(smtp_username, smtp_password)
        server.sendmail(sender, recipients, msg.as_string())
        server.close()
    except Exception as e:
        print ("Error in sending email: ", e)
    else:
        print ("Email sent!")

def monitorConsuleCluster():
    consul_leader_status=False
    region_response = requests.get('http://169.254.169.254/latest/meta-data/placement/availability-zone')
    region = region_response.content[:-1]
    list_of_instance_ips = gettagvalues(RESOURCE_TYPE,region)
    if len(list_of_instance_ips) != 0:
        if(getLeaderStatus(list_of_instance_ips,list_of_instance_ips[0],consulHTTPPort)):
            consul_leader_status=True
        else:
            if (getLeaderStatus(list_of_instance_ips, list_of_instance_ips[1], consulHTTPPort)):
                consul_leader_status = True
            else:
                consul_leader_status = False

    print("Leader status:%s Time: %s" % (consul_leader_status,time.strftime("%c")))
    if(consul_leader_status):
        print("Consul Leader Status OK,Region: %s" % (region))
    else:
        print("Consul leader Error. Sending Alert")
        sendEmail("Consul Leader Error. No Leader Found,Region: %s" % (region))

monitorConsuleCluster()

