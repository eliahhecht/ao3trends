zip -r ao3stats.zip main.rb vendor 
aws s3 mv ao3stats.zip s3://ehecht-deploy/ao3stats.zip 
aws lambda update-function-code --function-name ao3trends --s3-bucket ehecht-deploy --s3-key ao3stats.zip
aws s3 rm s3://ehecht-deploy/ao3stats.zip 
