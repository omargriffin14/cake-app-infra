const AWS = require('aws-sdk');
const s3 = new AWS.S3();
const ses = new AWS.SES({ region: 'us-east-1' });

exports.handler = async (event) => {
  const record = event.Records[0];
  const messageId = record.ses.mail.messageId;
  const bucket = process.env.EMAIL_BUCKET;
  const forwardTo = process.env.FORWARD_TO;
  const fromEmail = process.env.FROM_EMAIL;

  try {
    const data = await s3.getObject({
      Bucket: bucket,
      Key: messageId
    }).promise();

    const rawEmail = data.Body.toString('utf-8');
    const modifiedEmail = rawEmail
      .replace(/^From: .*/m, `From: Nela's Bakery <${fromEmail}>`)
      .replace(/^Reply-To: .*/m, '')
      .replace(/^Return-Path: .*/m, '');

    await ses.sendRawEmail({
      Destinations: [forwardTo],
      RawMessage: { Data: modifiedEmail },
      Source: fromEmail
    }).promise();

    console.log(`Email forwarded successfully to ${forwardTo}`);
    return { statusCode: 200 };

  } catch (error) {
    console.error('Error forwarding email:', error);
    throw error;
  }
};
